import Foundation

private final class PackageXML: NSObject, XMLParserDelegate {
    var elements: [(String, [String: String])] = []
    private var active: [Int] = []
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard elements.count < 100_000 else { parser.abortParsing(); return }
        elements.append((elementName.components(separatedBy: ":").last ?? elementName, attributes))
        active.append(elements.count - 1)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { _ = active.popLast() }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if let index = active.last { elements[index].1["#text", default: ""] += string }
    }

    static func read(_ data: Data) throws -> PackageXML {
        guard data.count <= 4 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
              text.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil,
              text.range(of: "<!ENTITY", options: .caseInsensitive) == nil else {
            throw ReaderFailure.message("Unsupported publication XML.")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let delegate = PackageXML()
        parser.delegate = delegate
        guard parser.parse() else { throw ReaderFailure.message("Invalid publication XML.") }
        return delegate
    }
}

enum OfflinePackageValidator {
    static func validate(_ local: LocalPublication) async throws {
        let members = Dictionary(uniqueKeysWithValues: local.publication.members.enumerated().map { ($0.element.path, $0.offset) })
        func read(_ path: String) async throws -> Data {
            guard let index = members[path] else { throw ReaderFailure.message("A required publication member is missing.") }
            return try await local.member(index)
        }
        let container = try PackageXML.read(await read("META-INF/container.xml"))
        guard let packagePath = container.elements.first(where: { $0.0 == "rootfile" && $0.1["media-type"] == "application/oebps-package+xml" })?.1["full-path"] else {
            throw ReaderFailure.message("The publication package document is missing.")
        }
        let packageBytes = try await read(packagePath)
        let package = try PackageXML.read(packageBytes)
        var items = [String: String]()
        for (name, attributes) in package.elements where name == "item" {
            guard let id = attributes["id"], items[id] == nil, let href = attributes["href"],
                  let base = URL(string: "https://publication.invalid/" + packagePath),
                  let url = URL(string: href, relativeTo: base)?.absoluteURL else {
                throw ReaderFailure.message("Invalid publication manifest item.")
            }
            if url.host == "publication.invalid", url.scheme == "https" {
                guard members[String(url.path.dropFirst())] != nil else {
                    throw ReaderFailure.message("A required publication member is missing.")
                }
            }
            let type = attributes["media-type"] ?? ""
            if ["application/xhtml+xml", "text/html", "image/svg+xml", "text/css"].contains(type), url.host == "publication.invalid" {
                let bytes = try await read(String(url.path.dropFirst()))
                guard bytes.count <= 4 * 1024 * 1024, let text = String(data: bytes, encoding: .utf8) else { throw ReaderFailure.message("Publication text exceeds the reader limit.") }
                if text.range(of: #"(?:\b(?:src|href|srcset)\s*=\s*["']\s*|url\(\s*["']?\s*)data:"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    throw ReaderFailure.message("Embedded data resources are unsupported. Use archive image and font members.")
                }
                if text.range(of: #"<(?:[\w.-]+:)?(?:iframe|object|embed|video|audio)(?:\s|/|>)|writing-mode\s*:\s*vertical|http-equiv\s*=\s*["']refresh["']"#, options: [.regularExpression, .caseInsensitive]) != nil {
                    throw ReaderFailure.message("This publication requires an unsupported interactive or vertical layout.")
                }
                let tokens = try NSRegularExpression(pattern: #"<[^>]*>|[^<]+"#)
                var count = 0
                tokens.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { _, _, stop in
                    count += 1
                    if count > 100_000 { stop.pointee = true }
                }
                guard count <= 100_000 else { throw ReaderFailure.message("Publication section exceeds the node limit.") }
            }
            items[id] = type
        }
        let spine = package.elements.filter { $0.0 == "itemref" }
        guard !spine.isEmpty, spine.allSatisfy({ ["application/xhtml+xml", "text/html"].contains(items[$0.1["idref"] ?? ""] ?? "") }) else {
            throw ReaderFailure.message("Unsupported publication spine.")
        }
        let defaultFixed = package.elements.contains { name, attributes in
            name == "meta" && ((attributes["property"] == "rendition:layout" && attributes["#text"]?.trimmingCharacters(in: .whitespacesAndNewlines) == "pre-paginated") ||
                (attributes["name"] == "fixed-layout" && ["true", "yes"].contains(attributes["content"]?.lowercased() ?? "")))
        }
        let layouts = Set(spine.map { entry in
            let properties = entry.1["properties"] ?? ""
            return properties.contains("rendition:layout-pre-paginated") ? "fixed" : properties.contains("rendition:layout-reflowable") ? "reflow" : defaultFixed ? "fixed" : "reflow"
        })
        guard layouts.count == 1 else { throw ReaderFailure.message("Mixed publication layouts are unsupported.") }
    }
}
