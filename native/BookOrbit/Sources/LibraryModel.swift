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
    var store: PublicationStore?
    var scope: SessionReference?
    var downloadsOnly = false
    var budgetGiB = 10
    var usageBytes: Int64 = 0
    var measuringStorage = false
    var busy = false
    var error: String?
    private var restored = false
    private var generation = 0
    private var connectingTransport: Transport?

    func connect() async {
        guard !busy else { return }
        busy = true
        let generation = generation
        defer { if generation == self.generation { busy = false; password = ""; connectingTransport = nil } }
        do {
            let api = try Transport(server: server)
            connectingTransport = api
            let before = try await api.identity()
            let credentials = try await api.login(username: username, password: password)
            await api.authorize(credentials)
            let me = try await api.account()
            guard credentials.user?.id == me.id, try await api.identity() == before else {
                throw ReaderFailure.message("Server or account changed during sign-in.")
            }
            let reference = SessionReference(origin: api.origin, identity: before.instanceId, account: me.id)
            try await api.verifyCapabilities(reference)
            guard generation == self.generation else { await api.invalidate(); return }
            await api.authorize(credentials, scope: reference)
            guard generation == self.generation else { await api.invalidate(); return }
            let localStore = try PublicationStore(root: Self.storageRoot, scope: reference)
            try CredentialStore().save(credentials, scope: reference)
            UserDefaults.standard.set(try JSONEncoder().encode(reference), forKey: "verified-session")
            store = localStore
            scope = reference
            downloadsOnly = false
            identity = before
            account = me
            transport = api
            await configureBudget(reference)
            guard generation == self.generation else { return }
            page = 0
            let result = try await api.books(query: query, page: 0)
            guard generation == self.generation else { return }
            books = result
            error = nil
        } catch { if generation == self.generation { self.error = error.localizedDescription } }
    }

    func load(page target: Int) async {
        guard !busy, target >= 0 else { return }
        busy = true
        let generation = generation
        defer { if generation == self.generation { busy = false } }
        do {
            let result: [Book]
            if downloadsOnly || transport == nil {
                result = try await store?.books(page: target, query: query) ?? []
            } else if let transport { result = try await transport.books(query: query, page: target) }
            else { return }
            guard generation == self.generation else { return }
            books = result
            page = target
            error = nil
        } catch { if generation == self.generation { self.error = error.localizedDescription } }
    }

    func restore() async {
        guard !restored else { return }
        restored = true
        guard let data = UserDefaults.standard.data(forKey: "verified-session"),
              let reference = try? JSONDecoder().decode(SessionReference.self, from: data) else { return }
        busy = true
        let generation = generation
        defer { if generation == self.generation { busy = false; connectingTransport = nil } }
        do {
            store = try PublicationStore(root: Self.storageRoot, scope: reference)
            scope = reference
            await configureBudget(reference)
            guard generation == self.generation else { return }
            downloadsOnly = true
            let offline = try await store?.books(page: 0) ?? []
            guard generation == self.generation else { return }
            books = offline
            let api = try Transport(server: reference.origin.absoluteString)
            connectingTransport = api
            let identity = try await api.identity()
            guard identity.instanceId == reference.identity else { throw ReaderFailure.message("Server identity changed. Sign in again.") }
            let stored = try CredentialStore().load(scope: reference)
            let renewed = try await api.refresh(stored)
            await api.authorize(renewed, scope: reference)
            let me = try await api.account()
            guard me.id == reference.account, try await api.identity() == identity else { throw ReaderFailure.message("Account scope changed. Sign in again.") }
            try await api.verifyCapabilities(reference)
            guard generation == self.generation else { await api.invalidate(); return }
            try CredentialStore().save(renewed, scope: reference)
            self.identity = identity
            account = me
            transport = api
            downloadsOnly = false
            let result = try await api.books(query: "", page: 0)
            guard generation == self.generation else { return }
            books = result
        } catch { if generation == self.generation { self.error = error.localizedDescription } }
    }

    func signOut() async {
        generation += 1
        await connectingTransport?.invalidate()
        connectingTransport = nil
        await transport?.invalidate()
        if let scope { CredentialStore().remove(scope: scope) }
        UserDefaults.standard.removeObject(forKey: "verified-session")
        transport = nil
        store = nil
        scope = nil
        account = nil
        identity = nil
        books = []
        password = ""
        error = nil
        busy = false
        measuringStorage = false
        usageBytes = 0
    }

    func reconnect() async { restored = false; await restore() }

    func updateBudget() async {
        guard let scope else { return }
        UserDefaults.standard.set(budgetGiB, forKey: "download-budget-\(scope.key)")
        await store?.setBudget(Int64(budgetGiB) * 1024 * 1024 * 1024)
    }

    private func configureBudget(_ scope: SessionReference) async {
        let saved = UserDefaults.standard.integer(forKey: "download-budget-\(scope.key)")
        budgetGiB = saved > 0 && saved <= 1000 ? saved : 10
        await store?.setBudget(Int64(budgetGiB) * 1024 * 1024 * 1024)
        Task { await refreshStorage() }
    }

    func refreshStorage() async {
        guard !measuringStorage, let store else { return }
        let generation = generation
        measuringStorage = true
        defer { if generation == self.generation { measuringStorage = false } }
        do {
            let bytes = try await store.diskBytes()
            guard generation == self.generation else { return }
            usageBytes = bytes
        } catch { if generation == self.generation { self.error = error.localizedDescription } }
    }

    static var storageRoot: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Publications", isDirectory: true)
    }
}
