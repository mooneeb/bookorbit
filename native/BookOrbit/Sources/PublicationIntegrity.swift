import Foundation

extension Publication {
    func validateIntegrity() throws {
        let publication = self
        guard version == 1, sourceRevision == sourceSha256 else { throw ReaderFailure.message("Unsupported publication manifest.") }
        guard publication.sourceBytes >= 22, publication.sourceBytes <= 512 * 1024 * 1024,
              publication.members.count <= 20_000,
              publication.sourceSha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw ReaderFailure.message("Unsupported publication manifest.")
        }
        var names = Set<String>()
        var total: Int64 = 0
        for member in publication.members {
            guard member.bytes >= 0, member.bytes <= 32 * 1024 * 1024, member.path.utf8.count <= 1024,
                  !member.path.hasPrefix("/"), !member.path.contains("\\"),
                  !member.path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  !member.path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(member.path.precomposedStringWithCanonicalMapping).inserted,
                  member.sha256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
                throw ReaderFailure.message("Invalid publication member.")
            }
            total += Int64(member.bytes)
            guard total <= 2 * 1024 * 1024 * 1024 else { throw ReaderFailure.message("Publication expansion limit exceeded.") }
        }
    }
}
