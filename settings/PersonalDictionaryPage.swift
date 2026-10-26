import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PersonalDictionaryPage: View {
  @ObservedObject var model: SettingsModel
  @State private var query = ""
  @State private var sort = WordSort.pinyin
  @State private var selection = Set<UUID>()
  @State private var editor: PersonalWord?
  @State private var preview: PersonalImportPreview?
  private enum WordSort: String, CaseIterable { case pinyin = "拼音", text = "词语", weight = "词频从高到低" }

  private var visibleWords: [PersonalWord] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return model.settings.personalWords.filter {
      query.isEmpty || $0.text.lowercased().contains(query) || $0.pinyin.contains(PersonalWord.normalizePinyin(query))
    }.sorted {
      if sort == .weight && $0.weight != $1.weight { return $0.weight > $1.weight }
      let first = sort == .text ? $0.text : $0.pinyin
      let second = sort == .text ? $1.text : $1.pinyin
      if first != second { return first.localizedStandardCompare(second) == .orderedAscending }
      return $0.key < $1.key
    }
  }
  private var selectedWord: PersonalWord? {
    selection.count == 1 ? model.settings.personalWords.first(where: { selection.contains($0.id) }) : nil
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("搜索词语或拼音", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索个人词条")
        Picker("排序", selection: $sort) {
          ForEach(WordSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }.frame(width: 165)
      }
      HStack(spacing: 12) {
        Button("新增", systemImage: "plus") { editor = PersonalWord(text: "", pinyin: "") }
        Button("编辑", systemImage: "pencil") { editor = selectedWord }.disabled(selectedWord == nil)
        Button("删除", systemImage: "minus") {
          model.settings.personalWords.removeAll { selection.contains($0.id) }
          selection = []
        }.disabled(selection.isEmpty)
        Spacer(minLength: 0)
        Button("导入…", systemImage: "square.and.arrow.down", action: chooseImport)
        Menu {
          ForEach(PersonalDictionaryFormat.allCases) { format in
            Button(format.title) { exportWords(format) }
          }
        } label: { Label("导出", systemImage: "square.and.arrow.up") }
          .disabled(model.settings.personalWords.isEmpty)
      }.controlSize(.small)
      Table(visibleWords, selection: $selection) {
        TableColumn("词语", value: \.text).width(min: 120)
        TableColumn("拼音", value: \.pinyin).width(min: 140)
        TableColumn("词频") { Text(String($0.weight)).monospacedDigit() }.width(85)
      }
      .frame(height: 320)
      .overlay {
        if visibleWords.isEmpty {
          VStack(spacing: 8) {
            Image(systemName: query.isEmpty ? "text.badge.plus" : "magnifyingglass").font(.title)
            Text(query.isEmpty ? "添加第一条个人词语" : "没有匹配的词条").font(.headline)
            Text(query.isEmpty ? "填写词语、拼音和词频，或从文本文件导入。" : "试试词语的一部分或无声调拼音。")
              .font(.callout).foregroundStyle(.secondary)
          }.padding().allowsHitTesting(false)
        }
      }
      HStack {
        Text("\(model.settings.personalWords.count) 条词语\(query.isEmpty ? "" : " · 显示 \(visibleWords.count) 条")")
        Spacer()
        if !selection.isEmpty { Text("已选择 \(selection.count) 条") }
      }.font(.caption).foregroundStyle(.secondary)
      Text("编辑和导入后，点击“保存并应用”使词条生效。删除个人词条不会清除自动学习记录；曾经学过的同名词仍可能出现在候选中。")
        .font(.callout).foregroundStyle(.secondary)
      Text("支持无声调全拼（音节用空格分隔，ü 可写 v）。个人词库会同时用于全拼和小鹤双拼。")
        .font(.caption).foregroundStyle(.secondary)
    }
    .disabled(model.busy || model.loadFailed)
    .onChange(of: query) { _, _ in selection.formIntersection(Set(visibleWords.map(\.id))) }
    .sheet(item: $editor) { value in
      PersonalWordEditor(word: value) { word in
        model.settings.personalWords = try QingTypePersonalDictionary.upsert(word, in: model.settings.personalWords)
        selection = [word.id]
      }
    }
    .sheet(item: $preview) { value in
      PersonalImportSheet(preview: value, existing: model.settings.personalWords) { result in
        model.settings.personalWords = result.words
        model.failed = false
        model.message = "\(result.summary)。点击“保存并应用”后生效。"
        preview = nil
      }
    }
  }

  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.title = "导入个人词库"
    panel.prompt = "预检查"
    panel.allowedContentTypes = ["csv", "tsv", "txt"].compactMap { UTType(filenameExtension: $0) }
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    model.busy = true
    Task {
      defer { model.busy = false }
      do {
        let result = try await Task.detached { try QingTypePersonalDictionary.preview(url: url) }.value
        preview = result
      } catch { model.failed = true; model.message = error.localizedDescription }
    }
  }

  private func exportWords(_ format: PersonalDictionaryFormat) {
    do {
      let data = try QingTypePersonalDictionary.export(model.settings.personalWords, format: format)
      if try PersonalDictionarySavePanel.write(data, name: "清言个人词库.\(format.rawValue)", extension: format.rawValue) {
        model.failed = false
        model.message = "已导出 \(model.settings.personalWords.count) 条个人词语。"
      }
    } catch { model.failed = true; model.message = error.localizedDescription }
  }
}

private struct PersonalWordEditor: View {
  let word: PersonalWord
  let onSave: (PersonalWord) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var text: String
  @State private var pinyin: String
  @State private var weight: String
  @State private var error: String?

  init(word: PersonalWord, onSave: @escaping (PersonalWord) throws -> Void) {
    self.word = word
    self.onSave = onSave
    _text = State(initialValue: word.text)
    _pinyin = State(initialValue: word.pinyin)
    _weight = State(initialValue: String(word.weight))
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(word.text.isEmpty ? "新增个人词语" : "编辑个人词语").font(.title2.bold())
      Form {
        TextField("词语", text: $text).accessibilityLabel("词语")
        TextField("拼音", text: $pinyin).accessibilityLabel("拼音")
        TextField("词频", text: $weight).accessibilityLabel("词频")
      }.textFieldStyle(.roundedBorder)
      Text("拼音示例：qing yan shu ru fa。词频为 0 到 1000000000 的整数，用于调整词表中的相对权重。")
        .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("完成") {
          do {
            guard let value = Int(weight.trimmingCharacters(in: .whitespaces)) else { throw SettingsError.invalid("词频不是整数。") }
            let updated = try PersonalWord(id: word.id, text: text, pinyin: pinyin, weight: value).normalized()
            try onSave(updated)
            dismiss()
          } catch { self.error = error.localizedDescription }
        }.keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 450)
  }
}

private struct PersonalImportSheet: View {
  let preview: PersonalImportPreview
  let existing: [PersonalWord]
  let onImport: (PersonalImportResult) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var policy = PersonalImportPolicy.keepExisting
  @State private var exportError: String?

  var body: some View {
    let result = QingTypePersonalDictionary.merge(preview, into: existing, policy: policy)
    VStack(alignment: .leading, spacing: 14) {
      Text("导入预检查").font(.title2.bold())
      Text(preview.name).font(.callout).foregroundStyle(.secondary)
      Picker("相同词语与拼音", selection: $policy) {
        ForEach(PersonalImportPolicy.allCases) { Text($0.title).tag($0) }
      }.pickerStyle(.segmented)
      Text(result.summary).font(.headline)
      List(Array(result.decisions.prefix(500))) { item in
        HStack(alignment: .top, spacing: 12) {
          Text("第 \(item.line) 行").monospacedDigit().frame(width: 75, alignment: .leading)
          Text(item.action.rawValue).foregroundStyle(item.action == .failed ? Color.red : Color.secondary).frame(width: 35)
          VStack(alignment: .leading, spacing: 3) {
            if let word = item.word { Text("\(word.text) · \(word.pinyin) · \(word.weight)") }
            if !item.reason.isEmpty { Text(item.reason).font(.caption).foregroundStyle(.secondary) }
          }
        }.font(.callout)
      }.frame(height: 300)
      Text("只导入检查通过的记录。预览显示前 500 条，统计与检查报告覆盖全部记录；已忽略 \(preview.ignoredLines) 个空行或注释行。")
        .font(.caption).foregroundStyle(.secondary)
      if let exportError { Text(exportError).font(.caption).foregroundStyle(.red) }
      HStack {
        Button("导出检查报告…") {
          do {
            _ = try PersonalDictionarySavePanel.write(QingTypePersonalDictionary.inspectionReport(result), name: "词库导入检查.csv", extension: "csv")
          } catch { exportError = error.localizedDescription }
        }
        Spacer()
        Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("导入到编辑区") { onImport(result) }.keyboardShortcut(.defaultAction).disabled(result.changedCount == 0)
      }
    }.padding(24).frame(width: 650)
  }
}

private enum PersonalDictionarySavePanel {
  static func write(_ data: Data, name: String, extension suffix: String) throws -> Bool {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [UTType(filenameExtension: suffix) ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return false }
    try data.write(to: url, options: .atomic)
    return true
  }
}
