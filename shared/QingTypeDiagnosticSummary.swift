import Foundation

enum QingTypeDiagnosticSummary {
  static func configuration(_ settings: QingTypeSettings) -> [String: Any] {
    ["schema": settings.schema, "pageSize": settings.pageSize, "fontSize": settings.fontSize,
     "nativeCandidates": settings.useSystemCandidates, "learningEnabled": settings.learningEnabled,
     "personalWordCount": settings.personalWords.count,
     "enabledDictionaryCount": settings.dictionaries.filter(\.enabled).count,
     "modelEnabled": settings.activeModel != nil, "iceInstalled": settings.rimeIce != nil]
  }
}
