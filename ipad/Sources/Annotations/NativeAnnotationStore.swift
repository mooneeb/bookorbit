import CryptoKit
import Foundation
import SQLite3

actor NativeAnnotationStore {
  private var database: OpaquePointer?
  private let root: URL
  private let encoder = JSONEncoder()
  private let decoder = JSONDecoder()
  private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  init(namespace: String) throws {
    let digest = SHA256.hash(data: Data(namespace.utf8)).map { String(format: "%02x", $0) }.joined()
    root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("BookOrbitAnnotations", isDirectory: true)
      .appendingPathComponent(digest, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(
        root.appendingPathComponent("annotations.sqlite").path, &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK
    else {
      if let db { sqlite3_close(db) }
      throw NativeAnnotationStorageError.unavailable
    }
    database = db
    sqlite3_busy_timeout(db, 5000)
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA synchronous=FULL;
      PRAGMA max_page_count=32768;
      PRAGMA journal_size_limit=1048576;
      CREATE TABLE IF NOT EXISTS records (
        key TEXT PRIMARY KEY, bookId INTEGER NOT NULL, clientId TEXT, kind TEXT NOT NULL,
        deleted INTEGER NOT NULL, search TEXT NOT NULL, data BLOB NOT NULL,
        owned INTEGER NOT NULL DEFAULT 1
      );
      CREATE INDEX IF NOT EXISTS records_book ON records(bookId);
      CREATE INDEX IF NOT EXISTS records_client ON records(clientId);
      CREATE TABLE IF NOT EXISTS changes (
        sequence INTEGER PRIMARY KEY AUTOINCREMENT, operationId TEXT UNIQUE NOT NULL,
        bookId INTEGER NOT NULL, clientId TEXT NOT NULL, status TEXT NOT NULL,
        data BLOB NOT NULL
      );
      CREATE INDEX IF NOT EXISTS changes_pending ON changes(status, bookId, sequence);
      CREATE INDEX IF NOT EXISTS changes_client ON changes(clientId, sequence);
      CREATE TABLE IF NOT EXISTS recovery (
        id TEXT PRIMARY KEY, bookId INTEGER NOT NULL, data BLOB NOT NULL
      );
      CREATE INDEX IF NOT EXISTS recovery_book ON recovery(bookId);
      CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      """
    guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(db)
      database = nil
      throw NativeAnnotationStorageError.unavailable
    }
    var probe: OpaquePointer?
    if sqlite3_prepare_v2(db, "SELECT owned FROM records LIMIT 0", -1, &probe, nil) != SQLITE_OK {
      guard
        sqlite3_exec(
          db, "ALTER TABLE records ADD COLUMN owned INTEGER NOT NULL DEFAULT 1", nil, nil, nil)
          == SQLITE_OK
      else {
        sqlite3_close(db)
        database = nil
        throw NativeAnnotationStorageError.unavailable
      }
    }
    sqlite3_finalize(probe)
    guard
      sqlite3_create_function_v2(
        db, "bookorbit_lower", 1, SQLITE_UTF8 | SQLITE_DETERMINISTIC, nil,
        { context, _, arguments in
          guard let value = arguments?[0], let bytes = sqlite3_value_text(value) else {
            sqlite3_result_null(context)
            return
          }
          let lowered = String(cString: bytes).lowercased()
          sqlite3_result_text(
            context, lowered, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }, nil, nil, nil) == SQLITE_OK
    else {
      sqlite3_close(db)
      database = nil
      throw NativeAnnotationStorageError.unavailable
    }
    let visiblePath =
      "CASE WHEN json_extract(CAST(NEW.data AS TEXT),'$.undoOperationId') IS NULL THEN '$.after' ELSE '$.before' END"
    let field: (String) -> String = {
      "json_extract(CAST(NEW.data AS TEXT),(\(visiblePath)) || '.\($0)')"
    }
    let projection = """
      INSERT INTO hub_pending(operationId,sequence,bookId,clientId,recordKey,itemId,visiblePath,kind,fileId,deleted,search)
      SELECT NEW.operationId,NEW.sequence,NEW.bookId,NEW.clientId,
        CASE WHEN json_extract(CAST(NEW.data AS TEXT),'$.after.id')>0
          THEN 'id:' || json_extract(CAST(NEW.data AS TEXT),'$.after.id')
          ELSE 'client:' || NEW.clientId END,
        json_extract(CAST(NEW.data AS TEXT),'$.after.id'),\(visiblePath),
        \(field("kind")),\(field("jumpFileId")),
        CASE WHEN \(field("id")) IS NULL THEN NULL WHEN \(field("deletedAt")) IS NULL THEN 0 ELSE 1 END,
        bookorbit_lower(COALESCE(\(field("text")),'') || ' ' || COALESCE(\(field("note")),''))
      WHERE NEW.status='pending';
      """
    let hubSchema = """
      CREATE TABLE IF NOT EXISTS hub_pending (
        operationId TEXT PRIMARY KEY,sequence INTEGER NOT NULL,bookId INTEGER NOT NULL,
        clientId TEXT NOT NULL,recordKey TEXT NOT NULL,itemId INTEGER NOT NULL,
        visiblePath TEXT NOT NULL,kind TEXT,fileId INTEGER,deleted INTEGER,search TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS hub_pending_client ON hub_pending(clientId,sequence DESC);
      CREATE INDEX IF NOT EXISTS hub_pending_record ON hub_pending(recordKey,sequence DESC);
      CREATE INDEX IF NOT EXISTS hub_pending_filter ON hub_pending(deleted,bookId,kind,fileId,sequence DESC);
      CREATE TRIGGER IF NOT EXISTS changes_hub_insert AFTER INSERT ON changes BEGIN
        \(projection)
      END;
      CREATE TRIGGER IF NOT EXISTS changes_hub_update AFTER UPDATE ON changes BEGIN
        DELETE FROM hub_pending WHERE operationId=OLD.operationId;
        \(projection)
      END;
      CREATE TRIGGER IF NOT EXISTS changes_hub_delete AFTER DELETE ON changes BEGIN
        DELETE FROM hub_pending WHERE operationId=OLD.operationId;
      END;
      """
    guard sqlite3_exec(db, hubSchema, nil, nil, nil) == SQLITE_OK else {
      sqlite3_close(db)
      database = nil
      throw NativeAnnotationStorageError.unavailable
    }
    var installed: OpaquePointer?
    sqlite3_prepare_v2(
      db, "SELECT value FROM metadata WHERE key='hubProjectionVersion'", -1, &installed, nil)
    let needsBackfill = sqlite3_step(installed) != SQLITE_ROW
    sqlite3_finalize(installed)
    if needsBackfill {
      let backfill = """
        BEGIN IMMEDIATE;
        UPDATE changes SET status=status WHERE status='pending';
        INSERT OR REPLACE INTO metadata(key,value) VALUES('hubProjectionVersion','1');
        COMMIT;
        """
      guard sqlite3_exec(db, backfill, nil, nil, nil) == SQLITE_OK else {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        sqlite3_close(db)
        database = nil
        throw NativeAnnotationStorageError.unavailable
      }
    }
  }

  func deviceID() throws -> String {
    if let value = try scalar("SELECT value FROM metadata WHERE key='device'") { return value }
    let value = UUID().uuidString.lowercased()
    try execute("INSERT INTO metadata(key,value) VALUES('device',?)", [.text(value)])
    return value
  }

  func close() {
    guard let database else { return }
    sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil)
    sqlite3_close(database)
    self.database = nil
  }

  nonisolated static func withOfflineBookRemovalProtection<T>(
    namespace: String, bookID: Int, remove: () throws -> T
  ) throws -> T {
    guard !namespace.isEmpty, bookID > 0 else { throw OfflineStorageError.unverifiedDownload }
    let root = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("BookOrbitAnnotations", isDirectory: true)
      .appendingPathComponent(OfflineResourceStore.hash(Data(namespace.utf8)), isDirectory: true)
    let file = root.appendingPathComponent("annotations.sqlite")
    guard FileManager.default.fileExists(atPath: file.path) else {
      throw OfflineStorageError.unverifiedDownload
    }
    var database: OpaquePointer?
    guard
      sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK, let database
    else {
      if let database { sqlite3_close(database) }
      throw OfflineStorageError.unverifiedDownload
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 5000)
    guard sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
      throw OfflineStorageError.unverifiedDownload
    }
    defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
    var statement: OpaquePointer?
    let sql = """
      SELECT 1 FROM changes WHERE bookId=? AND status='pending'
      UNION ALL SELECT 1 FROM recovery WHERE bookId=? LIMIT 1
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw OfflineStorageError.unverifiedDownload
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_bind_int64(statement, 1, Int64(bookID)) == SQLITE_OK,
      sqlite3_bind_int64(statement, 2, Int64(bookID)) == SQLITE_OK
    else { throw OfflineStorageError.unverifiedDownload }
    switch sqlite3_step(statement) {
    case SQLITE_ROW: throw OfflineStorageError.protectedDownload
    case SQLITE_DONE: return try remove()
    default: throw OfflineStorageError.unverifiedDownload
    }
  }

  func cursor(bookID: Int, fileID: Int? = nil) throws -> String {
    try scalar(
      "SELECT value FROM metadata WHERE key=?", [.text(cursorKey(bookID: bookID, fileID: fileID))])
      ?? "0"
  }

  func load(bookID: Int, limit: Int = 5000) throws -> [NativeAnnotationItem] {
    var items: [NativeAnnotationItem] = try decodeRows(
      "SELECT data FROM records WHERE bookId=? ORDER BY key LIMIT ?",
      [.integer(bookID), .integer(min(max(limit, 1), 10000))])
    let pending: [NativeAnnotationQueuedChange] = try decodeRows(
      "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence LIMIT 1000",
      [.integer(bookID)])
    for change in pending {
      items.removeAll { same($0, change.after) }
      if let visible = change.undoOperationId == nil ? change.after : change.before {
        items.append(visible)
      }
    }
    return items
  }

  func pendingCount() throws -> Int {
    Int(try scalar("SELECT COUNT(*) FROM changes WHERE status='pending'") ?? "0") ?? 0
  }

  func pendingBooks() throws -> [Int] {
    try strings(
      "SELECT DISTINCT CAST(bookId AS TEXT) FROM changes WHERE status='pending' LIMIT 1000"
    )
    .compactMap(Int.init)
  }

  func pendingSourceFiles(bookID: Int) throws -> [Int] {
    try strings(
      """
      SELECT DISTINCT CAST(json_extract(CAST(data AS TEXT),'$.after.jumpFileId') AS TEXT)
      FROM changes WHERE bookId=? AND status='pending'
      AND json_extract(CAST(data AS TEXT),'$.after.kind')='pdf_ink'
      AND json_extract(CAST(data AS TEXT),'$.after.jumpFileId') IS NOT NULL LIMIT 1000
      """, [.integer(bookID)]
    ).compactMap(Int.init)
  }

  func loadSourceInk(bookID: Int, fileID: Int, page: Int?) throws -> [NativeAnnotationItem] {
    var sql = """
      SELECT data FROM records WHERE bookId=? AND kind='pdf_ink'
      AND json_extract(CAST(data AS TEXT),'$.jumpFileId')=?
      """
    var bindings: [Binding] = [.integer(bookID), .integer(fileID)]
    if let page {
      sql += " AND json_extract(CAST(data AS TEXT),'$.pdf.page')=?"
      bindings.append(.integer(page))
    }
    sql += " ORDER BY key LIMIT 5000"
    var items: [NativeAnnotationItem] = try decodeRows(sql, bindings)
    let pending: [NativeAnnotationQueuedChange] = try decodeRows(
      "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence LIMIT 1000",
      [.integer(bookID)])
    for change in pending where change.after.kind == "pdf_ink" && change.after.jumpFileId == fileID
    {
      items.removeAll { same($0, change.after) }
      if let visible = change.undoOperationId == nil ? change.after : change.before,
        page == nil || page == visible.pdf?.page
      {
        items.append(visible)
      }
    }
    return items
  }

  func loadPDFPassages(bookID: Int, fileID: Int, page: Int) throws -> [NativeAnnotationItem] {
    var items: [NativeAnnotationItem] = try decodeRows(
      """
      SELECT data FROM records WHERE bookId=? AND owned=1 AND kind!='pdf_ink'
      AND json_extract(CAST(data AS TEXT),'$.jumpFileId')=?
      AND json_extract(CAST(data AS TEXT),'$.pdf.page')=? ORDER BY key LIMIT 500
      """, [.integer(bookID), .integer(fileID), .integer(page)])
    let pending: [NativeAnnotationQueuedChange] = try decodeRows(
      """
      SELECT data FROM changes WHERE bookId=? AND status='pending'
      AND json_extract(CAST(data AS TEXT),'$.after.kind')!='pdf_ink'
      AND (json_extract(CAST(data AS TEXT),'$.after.jumpFileId')=?
        OR json_extract(CAST(data AS TEXT),'$.before.jumpFileId')=?)
      ORDER BY sequence LIMIT 1000
      """, [.integer(bookID), .integer(fileID), .integer(fileID)])
    for change in pending {
      items.removeAll { same($0, change.after) }
      if let visible = change.undoOperationId == nil ? change.after : change.before,
        visible.jumpFileId == fileID, visible.pdf?.page == page
      {
        items.insert(visible, at: 0)
      }
    }
    return Array(items.prefix(500))
  }

  func knownBooks() throws -> [Int] {
    try strings("SELECT DISTINCT CAST(bookId AS TEXT) FROM records ORDER BY bookId LIMIT 10000")
      .compactMap(Int.init)
  }

  func enqueue(_ change: NativeAnnotationQueuedChange) throws {
    guard try pendingCount() < 1000,
      Int(try scalar("PRAGMA page_count") ?? "0") ?? 0 < 28672
    else { throw NativeAnnotationStorageError.full }
    try transaction {
      try writeChange(change)
      if change.before == nil { try writeRecord(change.after, owned: true) }
    }
  }

  func nextPending(bookID: Int) throws -> NativeAnnotationQueuedChange? {
    let values: [NativeAnnotationQueuedChange] = try decodeRows(
      "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence LIMIT 1",
      [.integer(bookID)])
    return values.first
  }

  func change(operationID: UUID) throws -> NativeAnnotationQueuedChange? {
    let values: [NativeAnnotationQueuedChange] = try decodeRows(
      "SELECT data FROM changes WHERE operationId=? LIMIT 1",
      [.text(operationID.uuidString.lowercased())])
    return values.first
  }

  func markAttempted(_ change: NativeAnnotationQueuedChange) throws -> Bool {
    guard let operationID = UUID(uuidString: change.operation.operationId),
      var value = try self.change(operationID: operationID), value.status == "pending"
    else { return false }
    value.attempted = true
    try writeChange(value)
    return true
  }

  func cancel(_ change: NativeAnnotationQueuedChange) throws {
    guard let operationID = UUID(uuidString: change.operation.operationId),
      let stored = try self.change(operationID: operationID), stored.status == "pending",
      !stored.attempted
    else { throw NativeAnnotationStorageError.recoveryRequired }
    let latest = try scalar(
      "SELECT operationId FROM changes WHERE clientId=? AND status='pending' ORDER BY sequence DESC LIMIT 1",
      [.text(change.operation.clientId)])
    guard latest == change.operation.operationId else {
      throw NativeAnnotationStorageError.newerChanges
    }
    guard !change.attempted else { throw NativeAnnotationStorageError.recoveryRequired }
    try transaction {
      var cancelled = change
      cancelled.status = "cancelled"
      try writeChange(cancelled)
      if change.before == nil {
        try execute("DELETE FROM records WHERE key=?", [.text(key(change.after))])
      }
    }
  }

  func requestUndo(_ change: NativeAnnotationQueuedChange) throws {
    guard let operationID = UUID(uuidString: change.operation.operationId),
      var stored = try self.change(operationID: operationID),
      ["pending", "applied"].contains(stored.status)
    else { throw NativeAnnotationStorageError.recoveryRequired }
    let latest = try scalar(
      "SELECT operationId FROM changes WHERE clientId=? AND status='pending' ORDER BY sequence DESC LIMIT 1",
      [.text(stored.operation.clientId)])
    guard latest == nil || latest == stored.operation.operationId else {
      throw NativeAnnotationStorageError.newerChanges
    }
    stored.undoOperationId = stored.undoOperationId ?? UUID().uuidString.lowercased()
    stored.status = "pending"
    try writeChange(stored)
  }

  func completeUndo(
    _ change: NativeAnnotationQueuedChange, inverse: NativeAnnotationQueuedChange
  ) throws {
    guard let operationID = UUID(uuidString: change.operation.operationId),
      var stored = try self.change(operationID: operationID), stored.status == "pending",
      stored.undoOperationId == inverse.operation.operationId,
      let acknowledged = stored.acknowledged
    else { throw NativeAnnotationStorageError.recoveryRequired }
    let current = try canonical(acknowledged)
    let latest = try scalar(
      "SELECT operationId FROM changes WHERE clientId=? AND status='pending' ORDER BY sequence DESC LIMIT 1",
      [.text(stored.operation.clientId)])
    guard current?.version == acknowledged.version,
      current?.deletedAt == acknowledged.deletedAt,
      latest == stored.operation.operationId
    else {
      try recover(stored, reason: "undo_newer_version", canonical: current)
      throw NativeAnnotationStorageError.newerChanges
    }
    try transaction {
      stored.status = "undone"
      try writeChange(stored)
      try writeChange(inverse)
    }
  }

  func applyDelta(_ delta: NativeAnnotationDelta, bookID: Int, fileID: Int? = nil) throws {
    guard delta.items.allSatisfy({ $0.bookId == bookID && $0.id > 0 && $0.version > 0 }) else {
      throw ConnectionError.invalidResponse
    }
    try transaction {
      let changes: [NativeAnnotationQueuedChange] = try decodeRows(
        "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence LIMIT 1000",
        [.integer(bookID)])
      for item in delta.items {
        try writeRecord(item, owned: fileID == nil)
        for change in changes where same(change.after, item) {
          if item.deletedAt != nil && ["update", "repair"].contains(change.operation.action) {
            try recover(change, reason: "committed_deletion", canonical: item)
          } else if let page = item.pageFingerprint, let expected = change.after.pageFingerprint,
            page != expected && change.after.kind == "pdf_ink"
          {
            try recover(change, reason: "source_replaced", canonical: item)
          }
        }
      }
      try execute(
        "INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)",
        [.text(cursorKey(bookID: bookID, fileID: fileID)), .text(delta.nextCursor)])
    }
  }

  func applyResult(_ result: NativeAnnotationOperationResult, change: NativeAnnotationQueuedChange)
    throws
  {
    guard result.operationId == change.operation.operationId,
      ["applied", "conflict", "recovery"].contains(result.status)
    else { throw ConnectionError.invalidResponse }
    guard let operationID = UUID(uuidString: change.operation.operationId),
      let stored = try self.change(operationID: operationID), stored.status == "pending"
    else { return }
    try transaction {
      if let item = result.annotation {
        guard item.bookId == change.operation.bookId, item.id > 0, item.version > 0 else {
          throw ConnectionError.invalidResponse
        }
        try writeRecord(item)
      }
      if result.status == "applied" {
        guard let acknowledged = result.annotation else { throw ConnectionError.invalidResponse }
        var completed = stored
        completed.attempted = true
        completed.status =
          completed.undoOperationId != nil
          ? "pending"
          : (result.publication.map { $0.status == "published" ? "applied" : "pending" }
            ?? "applied")
        completed.acknowledged = acknowledged
        try writeChange(completed)
      } else {
        try recover(change, reason: result.status, canonical: result.annotation)
      }
    }
  }

  func recoveryDrafts(bookID: Int?, limit: Int = 100) throws -> [NativeAnnotationRecoveryDraft] {
    if let bookID {
      return try decodeRows(
        "SELECT data FROM recovery WHERE bookId=? ORDER BY rowid DESC LIMIT ?",
        [.integer(bookID), .integer(min(max(limit, 1), 100))])
    }
    return try decodeRows(
      "SELECT data FROM recovery ORDER BY rowid DESC LIMIT ?", [.integer(min(max(limit, 1), 100))])
  }

  func recoveryDraftsPage(bookID: Int?, cursor: Int?, limit: Int) throws
    -> NativeAnnotationRecoveryPage
  {
    let size = min(max(limit, 1), 100)
    var sql = "SELECT data FROM recovery WHERE 1=1"
    var bindings: [Binding] = []
    if let bookID {
      sql += " AND bookId=?"
      bindings.append(.integer(bookID))
    }
    if let cursor {
      sql += " AND rowid<?"
      bindings.append(.integer(cursor))
    }
    sql += " ORDER BY rowid DESC LIMIT ?"
    bindings.append(.integer(size + 1))
    var items: [NativeAnnotationRecoveryDraft] = try decodeRows(sql, bindings)
    var nextCursor: Int?
    if items.count > size {
      items.removeLast()
      if let last = items.last {
        nextCursor = try scalar("SELECT rowid FROM recovery WHERE id=?", [.text(last.id)]).flatMap(
          Int.init)
      }
    }
    return NativeAnnotationRecoveryPage(items: items, nextCursor: nextCursor)
  }

  func retainSourceRecovery(bookID: Int, fileID: Int, reason: String) throws {
    try transaction {
      let changes: [NativeAnnotationQueuedChange] = try decodeRows(
        "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence LIMIT 1000",
        [.integer(bookID)])
      for change in changes where change.after.jumpFileId == fileID {
        try recover(change, reason: reason, canonical: nil)
      }
      let items: [NativeAnnotationItem] = try decodeRows(
        "SELECT data FROM records WHERE bookId=? LIMIT 10000", [.integer(bookID)])
      for item in items where item.jumpFileId == fileID {
        let operation = NativeAnnotationOperation(
          operationId: UUID().uuidString.lowercased(),
          clientId: item.clientId ?? UUID().uuidString.lowercased(),
          annotationId: item.id > 0 ? item.id : nil, bookId: bookID, baseVersion: item.version,
          action: "repair", payload: nil)
        let draft = NativeAnnotationRecoveryDraft(
          id: "source:\(fileID):\(item.id):\(item.version)",
          bookId: bookID, item: item, operation: operation, reason: reason,
          createdAt: Date().ISO8601Format())
        try writeDraft(draft)
        var detached = item
        detached.positionStatus = "failed"
        try writeRecord(detached)
      }
    }
  }

  func protectedSourceRevision(bookID: Int, fileID: Int, revision: String) throws -> Bool {
    let digest = revision.hasPrefix("sha256:") ? String(revision.dropFirst(7)) : revision
    guard digest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
      throw ConnectionError.invalidResponse
    }
    let revisions: [Binding] = [.text(digest), .text("sha256:\(digest)")]
    let pending = try scalar(
      """
      SELECT COUNT(*) FROM changes WHERE bookId=? AND status='pending'
      AND COALESCE(json_extract(CAST(data AS TEXT),'$.after.jumpFileId'),
        json_extract(CAST(data AS TEXT),'$.operation.payload.bookFileId'))=?
      AND (json_extract(CAST(data AS TEXT),'$.after.sourceRevision') IS NULL
        OR json_extract(CAST(data AS TEXT),'$.after.sourceRevision') IN (?, ?)
        OR json_extract(CAST(data AS TEXT),'$.before.sourceRevision') IN (?, ?))
      """, [.integer(bookID), .integer(fileID)] + revisions + revisions)
    if pending != "0" { return true }
    return try sourceRecoveryExists(bookID: bookID, fileID: fileID, revision: digest)
  }

  private func sourceRecoveryExists(bookID: Int, fileID: Int, revision: String) throws -> Bool {
    let sql = """
      SELECT 1 FROM recovery WHERE bookId=?
      AND COALESCE(json_extract(CAST(data AS TEXT),'$.item.jumpFileId'),
        json_extract(CAST(data AS TEXT),'$.operation.payload.bookFileId'))=?
      AND (COALESCE(json_extract(CAST(data AS TEXT),'$.item.sourceRevision'),
        json_extract(CAST(data AS TEXT),'$.operation.payload.sourceRevision')) IS NULL
        OR json_extract(CAST(data AS TEXT),'$.item.sourceRevision') IN (?, ?)
        OR json_extract(CAST(data AS TEXT),'$.operation.payload.sourceRevision') IN (?, ?))
      LIMIT 1
      """
    let revisions: [Binding] = [.text(revision), .text("sha256:\(revision)")]
    return try scalar(sql, [.integer(bookID), .integer(fileID)] + revisions + revisions)
      != nil
  }

  func importHub(_ items: [NativeAnnotationHubItem]) throws {
    try transaction {
      for item in items {
        let canonical = try decoder.decode(NativeAnnotationItem.self, from: encoder.encode(item))
        try writeRecord(canonical, owned: true)
        try execute(
          "INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)",
          [.text("bookTitle:\(item.bookId)"), .text(item.bookTitle ?? "Book \(item.bookId)")])
      }
    }
  }

  func bookTitle(_ bookID: Int) throws -> String? {
    try scalar("SELECT value FROM metadata WHERE key=?", [.text("bookTitle:\(bookID)")])
  }

  func current(_ item: NativeAnnotationItem) throws -> NativeAnnotationItem? {
    let pending: [NativeAnnotationQueuedChange] = try decodeRows(
      "SELECT data FROM changes WHERE bookId=? AND status='pending' ORDER BY sequence DESC LIMIT 1000",
      [.integer(item.bookId)])
    if let change = pending.first(where: { same($0.after, item) }) {
      return change.undoOperationId == nil ? change.after : change.before
    }
    return try canonical(item)
  }

  func canonical(_ item: NativeAnnotationItem) throws -> NativeAnnotationItem? {
    let rows: [NativeAnnotationItem] = try decodeRows(
      "SELECT data FROM records WHERE bookId=? AND (key=? OR (?<>'' AND clientId=?)) LIMIT 1",
      [
        .integer(item.bookId), .text(key(item)), .text(item.clientId ?? ""),
        .text(item.clientId ?? ""),
      ])
    return rows.first
  }

  func hub(query: [URLQueryItem], remote: NativeAnnotationHubResponse? = nil) throws
    -> NativeAnnotationHubResponse
  {
    let values = Dictionary(
      query.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    let limit = min(max(Int(values["limit"] ?? "40") ?? 40, 1), 100)
    let rawCursor = Int(values["cursor"] ?? "0") ?? 0
    guard rawCursor != Int.min else { throw NativeAnnotationStorageError.paginationChanged }
    let cursor = abs(rawCursor)
    let status = values["status"] ?? "active"
    let search = (values["search"] ?? "").lowercased()
    let matches: (NativeAnnotationItem) -> Bool = { item in
      (values["bookId"].flatMap(Int.init).map { $0 == item.bookId } ?? true)
        && (values["fileId"].flatMap(Int.init).map { $0 == item.jumpFileId } ?? true)
        && (values["kind"].map { $0 == item.kind } ?? true)
        && (status == "recovery" || ((status == "trashed") == (item.deletedAt != nil)))
        && (search.isEmpty || "\(item.text) \(item.note ?? "")".lowercased().contains(search))
    }
    var rows: [NativeAnnotationItem] = []
    var nextCursor = remote?.nextCursor
    if let remote {
      rows = try remote.items.map {
        try decoder.decode(NativeAnnotationItem.self, from: encoder.encode($0))
      }
    } else if status == "recovery" {
      rows = try recoveryDrafts(bookID: values["bookId"].flatMap(Int.init), limit: limit + 1)
        .compactMap(\.item)
    } else {
      let source = """
        records r LEFT JOIN hub_pending p ON p.operationId=(
          SELECT pending.operationId FROM hub_pending pending
          WHERE pending.recordKey=r.key OR (r.clientId<>'' AND pending.clientId=r.clientId)
          ORDER BY pending.sequence DESC LIMIT 1)
        """
      let deleted = "CASE WHEN p.operationId IS NULL THEN r.deleted ELSE p.deleted END"
      let kind = "CASE WHEN p.operationId IS NULL THEN r.kind ELSE p.kind END"
      let searchable = "CASE WHEN p.operationId IS NULL THEN r.search ELSE p.search END"
      var sql =
        "SELECT r.key,r.rowid AS cursor,p.operationId,p.visiblePath FROM \(source) WHERE r.owned=1 AND \(deleted)=?"
      var bindings: [Binding] = [.integer(status == "trashed" ? 1 : 0)]
      if let bookID = values["bookId"].flatMap(Int.init) {
        sql += " AND r.bookId=?"
        bindings.append(.integer(bookID))
      }
      if let fileID = values["fileId"].flatMap(Int.init) {
        sql +=
          " AND CASE WHEN p.operationId IS NULL THEN json_extract(CAST(r.data AS TEXT),'$.jumpFileId') ELSE p.fileId END=?"
        bindings.append(.integer(fileID))
      }
      if let requestedKind = values["kind"], !requestedKind.isEmpty {
        sql += " AND \(kind)=?"
        bindings.append(.text(requestedKind))
      }
      if !search.isEmpty {
        sql += " AND instr(\(searchable),?)>0"
        bindings.append(.text(search))
      }
      let group: String?
      switch values["groupBy"] {
      case "book": group = "r.bookId"
      case "kind": group = kind
      case "month": group = "substr(json_extract(CAST(r.data AS TEXT),'$.createdAt'),1,7)"
      case "source": group = "json_extract(CAST(r.data AS TEXT),'$.origin')"
      default: group = nil
      }
      if cursor > 0 {
        if let group {
          guard
            let anchor = try scalar(
              "SELECT \(group) FROM \(source) WHERE r.rowid=?", [.integer(cursor)])
          else {
            throw NativeAnnotationStorageError.paginationChanged
          }
          let direction = values["groupBy"] == "month" ? "<" : ">"
          sql += " AND (\(group)\(direction)? OR (\(group)=? AND r.rowid<?))"
          bindings.append(contentsOf: [.text(anchor), .text(anchor), .integer(cursor)])
        } else {
          sql += " AND r.rowid<?"
          bindings.append(.integer(cursor))
        }
      }
      if let group {
        sql +=
          " ORDER BY \(group) \(values["groupBy"] == "month" ? "DESC" : "ASC"),r.rowid DESC LIMIT ?"
      } else {
        sql += " ORDER BY r.rowid DESC LIMIT ?"
      }
      bindings.append(.integer(limit + 1))
      let projected = """
        WITH candidates AS MATERIALIZED (\(sql))
        SELECT json_object('cursor',page.cursor,'item',
          CASE WHEN page.operationId IS NULL THEN json(CAST(r.data AS TEXT))
            ELSE json_extract(CAST(c.data AS TEXT),page.visiblePath) END)
        FROM candidates page JOIN records r ON r.key=page.key
        LEFT JOIN changes c ON c.operationId=page.operationId
        """
      var localRows: [HubLocalRow] = try decodeRows(projected, bindings)
      if localRows.count > limit {
        localRows.removeLast()
        nextCursor = localRows.last.map { -$0.cursor }
      }
      rows = localRows.map(\.item)
    }
    if status != "recovery", remote != nil {
      let overlays = try hubPendingRows(page: rows, values: values, limit: limit, pageOnly: true)
      for overlay in overlays {
        if let index = rows.firstIndex(where: {
          $0.id == overlay.itemId || $0.clientId == overlay.clientId
        }) {
          if let visible = overlay.visible, matches(visible) {
            rows[index] = visible
          } else {
            rows.remove(at: index)
          }
        }
      }
      if cursor == 0, rows.count < limit {
        let additions = try hubPendingRows(
          page: rows, values: values, limit: limit - rows.count, pageOnly: false)
        for addition in additions {
          if let visible = addition.visible, matches(visible) { rows.append(visible) }
        }
      }
    }
    rows = rows.filter(matches)
    let metadata = Dictionary(
      (remote?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let visibleRows = Array(rows.prefix(limit))
    let titles = try hubBookTitles(bookIDs: Set(visibleRows.map(\.bookId)))
    let items = try visibleRows.map { item -> NativeAnnotationHubItem in
      var object =
        try JSONSerialization.jsonObject(with: encoder.encode(item)) as? [String: Any] ?? [:]
      let title = titles[item.bookId]
      object["bookTitle"] = metadata[item.id]?.bookTitle ?? title ?? "Book \(item.bookId)"
      object["author"] = metadata[item.id]?.author ?? NSNull()
      object["fileFormat"] = metadata[item.id]?.fileFormat ?? NSNull()
      let group: String
      switch values["groupBy"] {
      case "kind": group = item.kind
      case "month": group = String(item.createdAt.prefix(7))
      case "source": group = item.origin
      default: group = title ?? "Book \(item.bookId)"
      }
      object["groupKey"] = group
      return try decoder.decode(
        NativeAnnotationHubItem.self, from: JSONSerialization.data(withJSONObject: object))
    }
    return NativeAnnotationHubResponse(items: items, nextCursor: nextCursor)
  }

  private struct HubPendingRow: Decodable {
    var itemId: Int
    var clientId: String
    var visible: NativeAnnotationItem?
  }

  private struct HubLocalRow: Decodable {
    var cursor: Int
    var item: NativeAnnotationItem
  }

  private struct HubBookTitle: Decodable {
    var bookId: Int
    var title: String
  }

  private func hubBookTitles(bookIDs: Set<Int>) throws -> [Int: String] {
    guard !bookIDs.isEmpty else { return [:] }
    let keys = bookIDs.map { "bookTitle:\($0)" }
    let placeholders = Array(repeating: "?", count: keys.count).joined(separator: ",")
    let titles: [HubBookTitle] = try decodeRows(
      "SELECT json_object('bookId',CAST(substr(key,11) AS INTEGER),'title',value) FROM metadata WHERE key IN (\(placeholders))",
      keys.map(Binding.text))
    return Dictionary(titles.map { ($0.bookId, $0.title) }, uniquingKeysWith: { first, _ in first })
  }

  private func hubPendingRows(
    page: [NativeAnnotationItem], values: [String: String], limit: Int, pageOnly: Bool
  ) throws -> [HubPendingRow] {
    guard limit > 0, !pageOnly || !page.isEmpty else { return [] }
    var conditions = [
      "NOT EXISTS (SELECT 1 FROM hub_pending newer WHERE newer.clientId=p.clientId AND newer.sequence>p.sequence)",
      "EXISTS (SELECT 1 FROM records r WHERE r.owned=1 AND (r.key=p.recordKey OR (r.clientId<>'' AND r.clientId=p.clientId)))",
    ]
    var bindings: [Binding] = []
    let keys = page.map(key)
    let clients = page.compactMap(\.clientId)
    var identities: [String] = []
    if !keys.isEmpty {
      identities.append(
        "p.recordKey IN (\(Array(repeating: "?", count: keys.count).joined(separator: ",")))")
      bindings.append(contentsOf: keys.map(Binding.text))
    }
    if !clients.isEmpty {
      identities.append(
        "p.clientId IN (\(Array(repeating: "?", count: clients.count).joined(separator: ",")))")
      bindings.append(contentsOf: clients.map(Binding.text))
    }
    if !identities.isEmpty {
      conditions.append("\(pageOnly ? "" : "NOT ")(\(identities.joined(separator: " OR ")))")
    }
    if !pageOnly {
      conditions.append("p.deleted=?")
      bindings.append(.integer(values["status"] == "trashed" ? 1 : 0))
      if let bookID = values["bookId"].flatMap(Int.init) {
        conditions.append("p.bookId=?")
        bindings.append(.integer(bookID))
      }
      if let fileID = values["fileId"].flatMap(Int.init) {
        conditions.append("p.fileId=?")
        bindings.append(.integer(fileID))
      }
      if let kind = values["kind"], !kind.isEmpty {
        conditions.append("p.kind=?")
        bindings.append(.text(kind))
      }
      if let search = values["search"], !search.isEmpty {
        conditions.append("instr(p.search,?)>0")
        bindings.append(.text(search.lowercased()))
      }
    }
    bindings.append(.integer(min(limit, 100)))
    let sql = """
      WITH candidates AS MATERIALIZED (
        SELECT p.operationId,p.itemId,p.clientId,p.visiblePath FROM hub_pending p
        WHERE \(conditions.joined(separator: " AND ")) ORDER BY p.sequence DESC LIMIT ?
      )
      SELECT json_object('itemId',p.itemId,'clientId',p.clientId,'visible',
        json_extract(CAST(c.data AS TEXT),p.visiblePath))
      FROM candidates p JOIN changes c ON c.operationId=p.operationId
      """
    return try decodeRows(sql, bindings)
  }

  private func recover(
    _ change: NativeAnnotationQueuedChange, reason: String, canonical: NativeAnnotationItem?
  ) throws {
    let draft = NativeAnnotationRecoveryDraft(
      id: change.operation.operationId,
      bookId: change.operation.bookId, item: change.after, operation: change.operation,
      reason: reason, createdAt: Date().ISO8601Format())
    try writeDraft(draft)
    var recovered = change
    recovered.status = "recovery"
    recovered.acknowledged = canonical
    try writeChange(recovered)
    if change.after.id < 0 {
      try execute("DELETE FROM records WHERE key=?", [.text(key(change.after))])
    }
  }

  private func writeDraft(_ draft: NativeAnnotationRecoveryDraft) throws {
    try execute(
      "INSERT OR REPLACE INTO recovery(id,bookId,data) VALUES(?,?,?)",
      [.text(draft.id), .integer(draft.bookId), .blob(try encode(draft))])
  }

  private func writeChange(_ change: NativeAnnotationQueuedChange) throws {
    try execute(
      """
      INSERT INTO changes(operationId,bookId,clientId,status,data) VALUES(?,?,?,?,?)
      ON CONFLICT(operationId) DO UPDATE SET status=excluded.status,data=excluded.data
      """,
      [
        .text(change.operation.operationId), .integer(change.operation.bookId),
        .text(change.operation.clientId), .text(change.status), .blob(try encode(change)),
      ])
  }

  private func isOwned(_ item: NativeAnnotationItem) throws -> Bool {
    try scalar(
      "SELECT owned FROM records WHERE key=? OR (?<>'' AND clientId=?) LIMIT 1",
      [.text(key(item)), .text(item.clientId ?? ""), .text(item.clientId ?? "")]) == "1"
  }

  private func writeRecord(_ item: NativeAnnotationItem, owned requested: Bool? = nil) throws {
    let existing: [NativeAnnotationItem] = try decodeRows(
      "SELECT data FROM records WHERE key=? OR (?<>'' AND clientId=?) LIMIT 1",
      [.text(key(item)), .text(item.clientId ?? ""), .text(item.clientId ?? "")])
    if let current = existing.first, current.id > 0, current.version > item.version { return }
    let owned = try isOwned(item) || requested == true
    if item.id > 0, let clientID = item.clientId {
      try execute(
        "DELETE FROM records WHERE clientId=? AND key<>?", [.text(clientID), .text(key(item))])
    }
    try execute(
      """
      INSERT INTO records(key,bookId,clientId,kind,deleted,search,data,owned) VALUES(?,?,?,?,?,?,?,?)
      ON CONFLICT(key) DO UPDATE SET bookId=excluded.bookId,clientId=excluded.clientId,
        kind=excluded.kind,deleted=excluded.deleted,search=excluded.search,data=excluded.data,owned=excluded.owned
      """,
      [
        .text(key(item)), .integer(item.bookId), .text(item.clientId ?? ""),
        .text(item.kind), .integer(item.deletedAt == nil ? 0 : 1),
        .text("\(item.text) \(item.note ?? "")".lowercased()), .blob(try encode(item)),
        .integer(owned ? 1 : 0),
      ])
  }

  private func key(_ item: NativeAnnotationItem) -> String {
    item.id > 0 ? "id:\(item.id)" : "client:\(item.clientId ?? String(item.id))"
  }

  private func cursorKey(bookID: Int, fileID: Int?) -> String {
    fileID.map { "sourceCursor:\(bookID):\($0)" } ?? "cursor:\(bookID)"
  }

  private func same(_ left: NativeAnnotationItem, _ right: NativeAnnotationItem) -> Bool {
    left.id == right.id || (left.clientId != nil && left.clientId == right.clientId)
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let data = try encoder.encode(value)
    guard data.count <= 8 * 1024 * 1024 else { throw NativeAnnotationStorageError.full }
    return data
  }

  private enum Binding {
    case text(String)
    case integer(Int)
    case blob(Data)
  }

  private func prepare(_ sql: String, _ bindings: [Binding]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw NativeAnnotationStorageError.unavailable
    }
    for (offset, binding) in bindings.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch binding {
      case .text(let value): result = sqlite3_bind_text(statement, index, value, -1, transient)
      case .integer(let value): result = sqlite3_bind_int64(statement, index, Int64(value))
      case .blob(let value):
        result = value.withUnsafeBytes {
          sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), transient)
        }
      }
      if result != SQLITE_OK {
        sqlite3_finalize(statement)
        throw NativeAnnotationStorageError.unavailable
      }
    }
    return statement
  }

  private func execute(_ sql: String, _ bindings: [Binding] = []) throws {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    guard result == SQLITE_DONE || result == SQLITE_ROW else {
      if result == SQLITE_FULL { throw NativeAnnotationStorageError.full }
      throw NativeAnnotationStorageError.unavailable
    }
  }

  private func strings(_ sql: String, _ bindings: [Binding] = []) throws -> [String] {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var values: [String] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return values }
      guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
        throw NativeAnnotationStorageError.corrupt
      }
      values.append(String(cString: text))
    }
  }

  private func scalar(_ sql: String, _ bindings: [Binding] = []) throws -> String? {
    try strings(sql, bindings).first
  }

  private func decodeRows<T: Decodable>(_ sql: String, _ bindings: [Binding] = []) throws -> [T] {
    let statement = try prepare(sql, bindings)
    defer { sqlite3_finalize(statement) }
    var values: [T] = []
    while true {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { return values }
      guard result == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else {
        throw NativeAnnotationStorageError.corrupt
      }
      let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
      do { values.append(try decoder.decode(T.self, from: data)) } catch {
        throw NativeAnnotationStorageError.corrupt
      }
    }
  }

  private func transaction(_ work: () throws -> Void) throws {
    try execute("BEGIN IMMEDIATE")
    do {
      try work()
      try execute("COMMIT")
      sqlite3_wal_checkpoint_v2(database, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }
}
