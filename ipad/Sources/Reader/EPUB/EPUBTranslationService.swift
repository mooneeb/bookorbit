import Foundation

actor EPUBTranslationService {
  private let transport: EPUBLanguageToolTransport
  private var cachedToken: String?
  private var tokenExpiry = Date.distantPast

  init(transport: EPUBLanguageToolTransport) { self.transport = transport }

  func translate(_ text: String, target: String) async throws -> TranslationResult {
    let trimmed = EPUBLanguageToolTransport.trim(text)
    guard !trimmed.isEmpty, trimmed.utf16.count <= NativeTranslationVocabulary.characterLimit,
      NativeTranslationVocabulary.languages.contains(where: { $0.code == target })
    else { throw EPUBLanguageToolError.invalidResponse }
    do { return try await google(trimmed, target: target) } catch {
      try Task.checkCancellation()
      return try await azure(trimmed, target: target)
    }
  }

  func clearToken() {
    cachedToken = nil
    tokenExpiry = .distantPast
  }

  private func google(_ text: String, target: String) async throws -> TranslationResult {
    let url = try EPUBLanguageToolTransport.url(
      "https://translate.googleapis.com", path: "/translate_a/single",
      query: [
        .init(name: "client", value: "gtx"), .init(name: "dt", value: "t"),
        .init(name: "sl", value: "auto"), .init(name: "tl", value: target),
        .init(name: "q", value: text),
      ])
    let body = try await transport.json(url)
    guard let data = try JSONSerialization.jsonObject(with: body) as? [Any], data.count > 0,
      let sentences = data[0] as? [Any], sentences.count <= 1024
    else { throw EPUBLanguageToolError.invalidResponse }
    let translated = sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
    guard !translated.isEmpty, translated.utf16.count <= 16_000 else {
      throw EPUBLanguageToolError.invalidResponse
    }
    let language = data.count > 2 ? data[2] as? String : nil
    return .init(
      translatedText: translated, detectedSourceLang: boundedLanguage(language), provider: "Google")
  }

  private func token() async throws -> String {
    if let cachedToken, Date() < tokenExpiry { return cachedToken }
    let url = try EPUBLanguageToolTransport.url(
      "https://edge.microsoft.com", path: "/translate/auth")
    let (data, status) = try await transport.bytes(URLRequest(url: url), limit: 16 * 1024)
    guard status == 200 else { throw EPUBLanguageToolError.status(status) }
    guard let raw = String(data: data, encoding: .utf8) else {
      throw EPUBLanguageToolError.invalidResponse
    }
    let value = EPUBLanguageToolTransport.trim(raw)
    guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else {
      throw EPUBLanguageToolError.invalidResponse
    }
    try Task.checkCancellation()
    cachedToken = value
    tokenExpiry = Date().addingTimeInterval(7 * 60)
    return value
  }

  private func azure(_ text: String, target: String) async throws -> TranslationResult {
    let authorization = try await token()
    let url = try EPUBLanguageToolTransport.url(
      "https://api-edge.cognitive.microsofttranslator.com", path: "/translate",
      query: [.init(name: "to", value: target), .init(name: "api-version", value: "3.0")])
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(authorization)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": text]])
    let (body, status) = try await transport.bytes(request, limit: 512 * 1024)
    if status == 401 { clearToken() }
    guard status == 200 else { throw EPUBLanguageToolError.status(status) }
    guard let data = try JSONSerialization.jsonObject(with: body) as? [[String: Any]],
      let first = data.first, let translations = first["translations"] as? [[String: Any]],
      let translated = translations.first?["text"] as? String,
      !translated.isEmpty, translated.utf16.count <= 16_000
    else { throw EPUBLanguageToolError.invalidResponse }
    let language = (first["detectedLanguage"] as? [String: Any])?["language"] as? String
    return .init(
      translatedText: translated, detectedSourceLang: boundedLanguage(language), provider: "Azure")
  }

  private func boundedLanguage(_ value: String?) -> String {
    guard let value, !value.isEmpty, value.utf16.count <= 64 else { return "auto" }
    return value
  }
}
