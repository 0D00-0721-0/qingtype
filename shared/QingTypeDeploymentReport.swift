import Foundation

struct QingTypeDeploymentReport: Codable {
  var success: Bool
  var settingsHash: String
  var schema: String
  var dictionaryCount: Int
  var modelLanguage: String?
  var modelVerified = false
  var message: String
  var logDirectory: String
  var completedAt = Date()

  func modelWasLoaded(in logs: String) -> Bool {
    guard let language = modelLanguage else { return false }
    return logs.contains("use grammar: " + language) &&
      logs.contains("loading gram db:") && logs.contains(language + ".gram") &&
      logs.components(separatedBy: "\n").contains(where: {
        $0.contains("gram_db.cc:") && $0.contains("found double array image of size")
      }) && !logs.contains("failed to load grammar database: " + language)
  }
}
