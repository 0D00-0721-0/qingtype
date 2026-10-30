import Foundation
import CryptoKit
import Darwin

@main
struct ContentMemoryTests {
  struct Measurement: Codable {
    var digest: String
    var peakGrowth: Int64
    var repetitions: Int
    var cancelledReads: Int
    var targetDescriptorsAfter: Int
  }
  static let mib: Int64 = 1024 * 1024

  static func expect(_ condition: Bool, _ message: String) throws {
    guard condition else { throw SettingsError.invalid("FAIL: " + message) }
  }

  // Inspect only handles to this synthetic file, so unrelated runtime/socket
  // descriptors do not make cancellation tests flaky.
  static func descriptors(for file: URL, readStarted: Bool = false) throws -> Int {
    var target = stat()
    guard stat(file.path, &target) == 0 else { throw SettingsError.invalid("Cannot stat synthetic file") }
    return try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").compactMap(Int32.init).filter { fd in
      var info = stat()
      return fstat(fd, &info) == 0 && info.st_dev == target.st_dev && info.st_ino == target.st_ino &&
        (!readStarted || lseek(fd, 0, SEEK_CUR) > 0)
    }.count
  }

  static func worker(file: URL, repetitions: Int, cancel: Bool) async throws -> Measurement {
    try expect(try descriptors(for: file) == 0, "worker starts without an open synthetic file")
    var before = rusage(), after = rusage()
    getrusage(RUSAGE_SELF, &before)
    var cancelledReads = 0
    if cancel {
      let cancelled = Task { () throws -> String in
        withUnsafeCurrentTask { $0?.cancel() }
        return try QingTypeContent.digest(of: file, checkingCancellation: true)
      }
      do { _ = try await cancelled.value; throw SettingsError.invalid("FAIL: cancelled hash returned a usable digest") }
      catch is CancellationError { }
      try expect(try descriptors(for: file) == 0, "pre-cancelled hash leaves no target handle")
      for _ in 0..<5 {
        let inFlight = Task.detached { try QingTypeContent.digest(of: file, checkingCancellation: true) }
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var observedOpenHandle = false
        while ProcessInfo.processInfo.systemUptime < deadline {
          if try descriptors(for: file, readStarted: true) > 0 { observedOpenHandle = true; break }
          try await Task.sleep(nanoseconds: 100_000)
        }
        inFlight.cancel()
        do { _ = try await inFlight.value; throw SettingsError.invalid("FAIL: interrupted hash returned a usable digest") }
        catch is CancellationError { }
        try expect(observedOpenHandle, "in-flight cancellation occurs after bytes were read")
        try expect(try descriptors(for: file) == 0, "interrupted hash closes its target handle")
        cancelledReads += 1
      }
    }
    var digest = ""
    for _ in 0..<repetitions {
      let next = try autoreleasepool { try QingTypeContent.digest(of: file) }
      try expect(digest.isEmpty || digest == next, "repeated verification returns the same digest")
      digest = next
      try expect(try descriptors(for: file) == 0, "successful hash closes its target handle")
    }
    getrusage(RUSAGE_SELF, &after)
    return Measurement(digest: digest, peakGrowth: Int64(after.ru_maxrss - before.ru_maxrss),
                       repetitions: repetitions, cancelledReads: cancelledReads,
                       targetDescriptorsAfter: try descriptors(for: file))
  }

  static func runWorker(file: URL, repetitions: Int = 1, cancel: Bool = false) throws -> Measurement {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    child.arguments = [cancel ? "--cancel-file" : "--hash-file", file.path, String(repetitions)]
    let pipe = Pipe(); child.standardOutput = pipe
    try child.run()
    let output = pipe.fileHandleForReading.readDataToEndOfFile(); child.waitUntilExit()
    try expect(child.terminationStatus == 0, "memory-test worker failed")
    return try JSONDecoder().decode(Measurement.self, from: output)
  }

  static func main() async throws {
    if CommandLine.arguments.count >= 3 && ["--hash-file", "--cancel-file"].contains(CommandLine.arguments[1]) {
      let repetitions = CommandLine.arguments.count == 4 ? Int(CommandLine.arguments[3]) ?? 0 : 1
      try expect((1...10).contains(repetitions), "invalid worker repetition count")
      let measurement = try await worker(file: URL(fileURLWithPath: CommandLine.arguments[2]),
                                         repetitions: repetitions, cancel: CommandLine.arguments[1] == "--cancel-file")
      print(String(decoding: try JSONEncoder().encode(measurement), as: UTF8.self))
      return
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("qingtype-content-memory-\(UUID())")
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let sizes = [64, 256, 1024]
    var files: [Int: URL] = [:], digests: [Int: String] = [:]
    var measurements: [Measurement] = []
    let zero = Data(repeating: 0, count: Int(mib))
    let prefix = Data("QingType synthetic memory fixture".utf8)
    let suffix = Data("End of synthetic fixture".utf8)
    var first = zero, last = zero
    first.replaceSubrange(0..<prefix.count, with: prefix)
    last.replaceSubrange((last.count - suffix.count)..<last.count, with: suffix)
    for size in sizes {
      let file = root.appendingPathComponent("synthetic-\(size)MiB.bin")
      fm.createFile(atPath: file.path, contents: nil)
      let handle = try FileHandle(forWritingTo: file)
      try handle.truncate(atOffset: UInt64(Int64(size) * mib))
      try handle.seek(toOffset: 0); try handle.write(contentsOf: prefix)
      try handle.seek(toOffset: UInt64(Int64(size) * mib) - UInt64(suffix.count)); try handle.write(contentsOf: suffix)
      try handle.close()
      var expected = SHA256()
      for index in 0..<size { expected.update(data: index == 0 ? first : index == size - 1 ? last : zero) }
      let expectedDigest = expected.finalize().map { String(format: "%02x", $0) }.joined()
      files[size] = file; digests[size] = expectedDigest
      let result = try runWorker(file: file)
      try expect(result.digest == expectedDigest, "\(size) MiB verification changed the digest")
      // A fresh worker per size prevents earlier peak allocations masking growth.
      try expect(result.peakGrowth < 64 * mib, "\(size) MiB hashing retained file-sized memory: \(result.peakGrowth)")
      try expect(result.targetDescriptorsAfter == 0, "hash left the synthetic file open")
      measurements.append(result)
    }
    try expect(measurements.last!.peakGrowth - measurements.first!.peakGrowth < 32 * mib,
               "peak memory scales with the file instead of the read buffer")
    let repeated = try runWorker(file: files[256]!, repetitions: 8)
    try expect(repeated.digest == digests[256] && repeated.peakGrowth < 64 * mib,
               "repeated verification accumulates file-sized memory or changes the digest")
    let cancelled = try runWorker(file: files[1024]!, cancel: true)
    try expect(cancelled.cancelledReads == 5 && cancelled.targetDescriptorsAfter == 0,
               "deterministic cancellation did not release all target handles")
    try expect(cancelled.digest == digests[1024] && cancelled.peakGrowth < 64 * mib,
               "cancel/retry retained file-sized memory or changed the file")
    if let path = ProcessInfo.processInfo.environment["QINGTYPE_MEMORY_REPORT"] {
      struct Report: Codable {
        var fileSizesMiB: [Int]
        var sizes: [Measurement]
        var repeated: Measurement
        var cancelled: Measurement
      }
      let data = try JSONEncoder().encode(Report(fileSizesMiB: sizes, sizes: measurements, repeated: repeated, cancelled: cancelled))
      try data.write(to: URL(fileURLWithPath: path), options: .atomic)
      try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
    print("PASS: SHA-256 is correct for nonzero 64, 256 and 1024 MiB sparse fixtures")
    print("PASS: fresh-process peak memory stays below 64 MiB and size-growth below 32 MiB")
    print("PASS: eight repeated 256 MiB verifications keep bounded memory and close target handles")
    print("PASS: pre-cancelled verification opens no target handle")
    print("PASS: five in-flight cancellations occur after reading starts and release every target handle")
    print("PASS: verification after cancellation preserves the 1 GiB digest and bounded peak memory")
  }
}
