import Foundation

actor EPUBDictionaryService {
  private struct SenseBlock {
    var partOfSpeech: String
    var definitions: [DictionaryDefinition]
  }

  private struct Payload {
    let word: String
    let phonetic: String?
    let audioURL: String?
    let blocks: [SenseBlock]
  }

  private let transport: EPUBLanguageToolTransport

  init(transport: EPUBLanguageToolTransport) { self.transport = transport }

  func lookup(_ selection: String, language: String) async throws -> DictionaryResult? {
    let word = EPUBLanguageToolTransport.trim(selection)
    guard !word.isEmpty, word.utf16.count <= 16_000 else {
      throw EPUBLanguageToolError.invalidResponse
    }
    let language = EPUBDictionaryVocabulary.normalizeLanguage(language)
    if language == "en" {
      var payload: Payload?
      do { payload = try await freeDictionary(word) } catch { try Task.checkCancellation() }
      if let payload {
        let entries = try await expand(payload, language: language, free: true)
        return .init(
          word: payload.word, phonetic: payload.phonetic, audioUrl: payload.audioURL,
          entries: entries, provider: "free-dictionary")
      }
    }
    guard let payload = try await wiktionary(word, language: language) else { return nil }
    return .init(
      word: payload.word, phonetic: nil, audioUrl: nil,
      entries: try await expand(payload, language: language, free: false), provider: "wiktionary")
  }

  private func freeDictionary(_ word: String) async throws -> Payload? {
    let url = try EPUBLanguageToolTransport.wordURL(
      "https://api.dictionaryapi.dev", prefix: "/api/v2/entries/en/", word: word)
    let (body, status) = try await transport.bytes(URLRequest(url: url), limit: 512 * 1024)
    if status == 404 { return nil }
    guard status == 200 else { throw EPUBLanguageToolError.status(status) }
    guard let entries = try JSONSerialization.jsonObject(with: body) as? [[String: Any]] else {
      throw EPUBLanguageToolError.invalidResponse
    }
    guard let entry = entries.first else { return nil }
    var phonetic = text(entry["phonetic"], maximum: 500)
    var audioURL: String?
    if let phonetics = entry["phonetics"] as? [[String: Any]] {
      for item in phonetics.prefix(32) {
        let value = text(item["text"], maximum: 500)
        if let audio = text(item["audio"], maximum: 4096), !audio.isEmpty {
          audioURL = audio
          if let value, !value.isEmpty { phonetic = value }
          break
        }
        if phonetic == nil, let value, !value.isEmpty { phonetic = value }
      }
    }
    let meanings = entry["meanings"] as? [[String: Any]] ?? []
    let blocks = merge(
      meanings.prefix(128).map { meaning in
        let definitions = meaning["definitions"] as? [[String: Any]] ?? []
        return SenseBlock(
          partOfSpeech: text(meaning["partOfSpeech"], maximum: 128) ?? "",
          definitions: definitions.prefix(128).compactMap { definition in
            guard let value = text(definition["definition"], maximum: 8192), !value.isEmpty else {
              return nil
            }
            return .init(definition: value, example: text(definition["example"], maximum: 8192))
          })
      })
    guard !blocks.isEmpty else { return nil }
    return .init(
      word: text(entry["word"], maximum: 16_000) ?? word,
      phonetic: phonetic, audioURL: audioURL, blocks: blocks)
  }

  private func wiktionary(_ word: String, language: String) async throws -> Payload? {
    let url = try EPUBLanguageToolTransport.wordURL(
      "https://\(language).wiktionary.org", prefix: "/api/rest_v1/page/definition/", word: word)
    let (body, status) = try await transport.bytes(URLRequest(url: url), limit: 512 * 1024)
    if status == 404 { return nil }
    guard status == 200 else { throw EPUBLanguageToolError.status(status) }
    guard let data = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
      throw EPUBLanguageToolError.invalidResponse
    }
    guard let entries = data[language] as? [[String: Any]] else { return nil }
    let blocks = merge(
      entries.prefix(128).map { entry in
        let definitions = entry["definitions"] as? [[String: Any]] ?? []
        return SenseBlock(
          partOfSpeech: text(entry["partOfSpeech"], maximum: 128) ?? "",
          definitions: definitions.prefix(128).compactMap { definition in
            guard let html = text(definition["definition"], maximum: 8192) else { return nil }
            let value = EPUBDictionaryVocabulary.plainText(html)
            guard !value.isEmpty else { return nil }
            let examples = definition["examples"] as? [Any] ?? []
            var example: String?
            for item in examples.prefix(32) {
              let raw = (item as? String) ?? ((item as? [String: Any])?["text"] as? String)
              if let raw = text(raw, maximum: 8192) {
                example = EPUBDictionaryVocabulary.plainText(raw)
                break
              }
            }
            return .init(definition: value, example: example)
          })
      })
    guard !blocks.isEmpty else { return nil }
    return .init(word: word, phonetic: nil, audioURL: nil, blocks: blocks)
  }

  private func merge(_ blocks: [SenseBlock]) -> [SenseBlock] {
    var result: [SenseBlock] = []
    var indices: [String: Int] = [:]
    for block in blocks where !block.definitions.isEmpty {
      if let index = indices[block.partOfSpeech] {
        let remaining = max(0, 128 - result[index].definitions.count)
        result[index].definitions.append(contentsOf: block.definitions.prefix(remaining))
      } else if result.count < 32 {
        indices[block.partOfSpeech] = result.count
        result.append(block)
      }
    }
    return result
  }

  private func expand(_ root: Payload, language: String, free: Bool) async throws
    -> [DictionaryEntry]
  {
    var entries: [DictionaryEntry] = []
    var visited: Set<String> = [root.word.lowercased()]
    var queue: [(word: String, blocks: [SenseBlock], depth: Int)] = [(root.word, root.blocks, 0)]
    var cursor = 0
    var lookups = 0
    while cursor < queue.count {
      try Task.checkCancellation()
      let current = queue[cursor]
      cursor += 1
      for block in current.blocks {
        entries.append(
          .init(
            partOfSpeech: block.partOfSpeech, definitions: Array(block.definitions.prefix(5)),
            sourceWord: current.word))
      }
      guard current.depth < 2 else { continue }
      for block in current.blocks {
        guard lookups < 3 else { break }
        guard let leading = block.definitions.first,
          let lemma = EPUBDictionaryVocabulary.pointerLemma(leading.definition),
          !visited.contains(lemma)
        else { continue }
        visited.insert(lemma)
        lookups += 1
        do {
          let payload: Payload?
          if free {
            payload = try await freeDictionary(lemma)
          } else {
            payload = try await wiktionary(lemma, language: language)
          }
          if let payload { queue.append((lemma, payload.blocks, current.depth + 1)) }
        } catch { try Task.checkCancellation() }
      }
    }
    return entries
  }

  private func text(_ value: Any?, maximum: Int) -> String? {
    guard let value = value as? String, value.utf16.count <= maximum else { return nil }
    return value
  }
}
