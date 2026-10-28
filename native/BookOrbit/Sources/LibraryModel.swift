import SwiftUI

@MainActor @Observable
final class LibraryModel {
    var server = "https://books.mooneeb.dev"
    var username = ""
    var password = ""
    var query = ""
    var books: [Book] = []
    var page = 0
    var account: Account?
    var identity: ServerIdentity?
    var transport: Transport?
    var busy = false
    var error: String?
    private var restored = false

    func connect() async {
        guard !busy else { return }
        busy = true
        defer { busy = false; password = "" }
        do {
            let api = try Transport(server: server)
            let before = try await api.identity()
            let credentials = try await api.login(username: username, password: password)
            await api.authorize(credentials)
            let me = try await api.account()
            guard credentials.user?.id == me.id, try await api.identity() == before else {
                throw ReaderFailure.message("Server or account changed during sign-in.")
            }
            let reference = SessionReference(origin: api.origin, identity: before.instanceId, account: me.id)
            try CredentialStore().save(credentials, scope: reference)
            UserDefaults.standard.set(try JSONEncoder().encode(reference), forKey: "verified-session")
            await api.authorize(credentials, scope: reference)
            identity = before
            account = me
            transport = api
            page = 0
            books = try await api.books(query: query, page: 0)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func load(page target: Int) async {
        guard !busy, let transport else { return }
        busy = true
        defer { busy = false }
        do {
            let result = try await transport.books(query: query, page: target)
            books = result
            page = target
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard let data = UserDefaults.standard.data(forKey: "verified-session"),
              let reference = try? JSONDecoder().decode(SessionReference.self, from: data) else { return }
        busy = true
        defer { busy = false }
        do {
            let api = try Transport(server: reference.origin.absoluteString)
            let identity = try await api.identity()
            guard identity.instanceId == reference.identity else { throw ReaderFailure.message("Server identity changed. Sign in again.") }
            let stored = try CredentialStore().load(scope: reference)
            let renewed = try await api.refresh(stored)
            try CredentialStore().save(renewed, scope: reference)
            await api.authorize(renewed, scope: reference)
            let me = try await api.account()
            guard me.id == reference.account, try await api.identity() == identity else { throw ReaderFailure.message("Account scope changed. Sign in again.") }
            self.identity = identity
            account = me
            transport = api
            books = try await api.books(query: "", page: 0)
        } catch { self.error = error.localizedDescription }
    }

    func signOut() async {
        await transport?.invalidate()
        if let transport, let identity, let account {
            CredentialStore().remove(scope: SessionReference(origin: transport.origin, identity: identity.instanceId, account: account.id))
        }
        UserDefaults.standard.removeObject(forKey: "verified-session")
        transport = nil
        account = nil
        identity = nil
        books = []
        password = ""
        error = nil
    }
}
