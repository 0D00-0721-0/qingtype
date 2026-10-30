import Foundation

struct QingTypeCandidate: Equatable {
  let index: Int
  let text: String
}

enum QingTypeCandidateSource {
  // Read a bounded snapshot without changing the engine page. All UI selections
  // use absolute indices, including candidates beyond the current Rime page.
  static func read(api: RimeApi_stdbool, session: RimeSessionId, startingAt start: Int,
                   limit: Int = 64) -> [QingTypeCandidate] {
    guard start >= 0, limit > 0, start <= Int(Int32.max) else { return [] }
    var iterator = RimeCandidateListIterator()
    guard api.candidate_list_from_index(session, &iterator, Int32(start)) else { return [] }
    defer { api.candidate_list_end(&iterator) }
    var result: [QingTypeCandidate] = []
    while result.count < limit && api.candidate_list_next(&iterator) {
      guard let value = iterator.candidate.text else { continue }
      result.append(QingTypeCandidate(index: Int(iterator.index), text: String(cString: value)))
    }
    return result
  }
}
