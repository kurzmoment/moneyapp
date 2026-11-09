import CSQLite
import Foundation

/// Durable, local storage for the complete MoneyApp ledger.
///
/// SQLite owns the individual entity rows while JSON is used only for the
/// payload of a row and for portable backups. This keeps normal saves small
/// and leaves the model independent of SQLite.
public actor SQLiteStore {
  public enum StoreError: Error, LocalizedError {
    case invalidDatabaseURL
    case sqlite(String)
    case unsupportedSchemaVersion(Int)
    case corruptData(String)
    case invalidBackup(String)
    case backupTooLarge
    case transactionRollbackFailed(String)

    public var errorDescription: String? {
      switch self {
      case .invalidDatabaseURL:
        "Databázový soubor musí být lokální soubor."
      case .sqlite(let message):
        "SQLite chyba: \(message)"
      case .unsupportedSchemaVersion(let version):
        "Nepodporovaná verze databáze: \(version)."
      case .corruptData(let message):
        "Databáze obsahuje neplatná data: \(message)"
      case .invalidBackup(let message):
        "Neplatná záloha: \(message)"
      case .backupTooLarge:
        "Záloha je příliš velká."
      case .transactionRollbackFailed(let message):
        "Transakce selhala a rollback se nepodařil: \(message)"
      }
    }
  }

  private struct BackupEnvelope: Codable {
    let schemaVersion: Int
    let snapshot: Snapshot
  }

  private struct Extras: Codable {
    var savingsGoals: [SavingsGoal] = []
    var balanceChecks: [BalanceCheck] = []
    var transactionHistory: [TransactionChange] = []
    var loans: [Loan] = []
    var investments: [InvestmentPortfolio] = []

    private enum CodingKeys: String, CodingKey {
      case savingsGoals, balanceChecks, transactionHistory, loans, investments
    }

    init(
      savingsGoals: [SavingsGoal] = [], balanceChecks: [BalanceCheck] = [],
      transactionHistory: [TransactionChange] = [], loans: [Loan] = [],
      investments: [InvestmentPortfolio] = []
    ) {
      self.savingsGoals = savingsGoals
      self.balanceChecks = balanceChecks
      self.transactionHistory = transactionHistory
      self.loans = loans
      self.investments = investments
    }

    init(from decoder: Decoder) throws {
      let values = try decoder.container(keyedBy: CodingKeys.self)
      savingsGoals = try values.decode([SavingsGoal].self, forKey: .savingsGoals)
      balanceChecks = try values.decode([BalanceCheck].self, forKey: .balanceChecks)
      transactionHistory = try values.decode([TransactionChange].self, forKey: .transactionHistory)
      loans = try values.decode([Loan].self, forKey: .loans)
      investments = try values.decode([InvestmentPortfolio].self, forKey: .investments)
    }
  }

  private struct LegacyExtras: Codable {
    var savingsGoals: [SavingsGoal]
    var balanceChecks: [BalanceCheck]
    var transactionHistory: [TransactionChange]
  }

  /// SQLite's C pointer is kept behind one explicitly-owned, unchecked
  /// Sendable handle. The actor is the only owner and serializes all use;
  /// the handle closes the connection when the actor is released.
  private final class SQLiteConnection: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
      self.pointer = pointer
    }

    deinit {
      sqlite3_close(pointer)
    }
  }

  private static let schemaVersion = 6
  private static let maximumBackupBytes = 50_000_000
  private static let dailyBackupKeepCount = 7
  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private let url: URL
  private let connection: SQLiteConnection
  private var db: OpaquePointer { connection.pointer }

  public init(url: URL) throws {
    guard url.isFileURL else { throw StoreError.invalidDatabaseURL }
    self.url = url

    let parent = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

    var opened: OpaquePointer?
    let result = sqlite3_open_v2(
      url.path,
      &opened,
      SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
      nil
    )
    guard result == SQLITE_OK, let opened else {
      let message =
        opened.map { String(cString: sqlite3_errmsg($0)) } ?? "database could not be opened"
      if let opened { sqlite3_close(opened) }
      throw StoreError.sqlite(message)
    }
    do {
      try Self.migrate(opened)
    } catch {
      sqlite3_close(opened)
      throw error
    }
    self.connection = SQLiteConnection(opened)
  }

  /// Loads all entity rows. A newly-created database gets the product's
  /// default empty snapshot; a database that has been explicitly saved as
  /// empty remains empty (and does not regain demo categories).
  public func load() throws -> Snapshot {
    let accounts = try decodeRows(table: "accounts", as: Account.self)
    let categories = try decodeRows(table: "categories", as: Category.self)
    let transactions = try decodeRows(table: "transactions", as: Transaction.self)
    let budgets = try decodeRows(table: "budgets", as: Budget.self)
    let recurringPayments = try decodeRows(table: "recurring_payments", as: RecurringPayment.self)
    let extras: Extras
    if let data = try metadataValue(for: "extras") {
      do { extras = try JSONDecoder().decode(Extras.self, from: data) } catch {
        throw StoreError.corruptData("extras nelze načíst: \(error.localizedDescription)")
      }
    } else {
      throw StoreError.corruptData("Chybí historie, cíle a kontroly zůstatků.")
    }
    guard let marker = try metadataValue(for: "has_state"),
      marker == Data([0]) || marker == Data([1])
    else {
      throw StoreError.corruptData("chybí nebo je poškozený stav inicializace")
    }
    let hasSavedState = marker == Data([1])

    if !hasSavedState && accounts.isEmpty && categories.isEmpty && transactions.isEmpty
      && budgets.isEmpty && recurringPayments.isEmpty && extras.savingsGoals.isEmpty
      && extras.balanceChecks.isEmpty && extras.transactionHistory.isEmpty
      && extras.loans.isEmpty && extras.investments.isEmpty
    {
      let initial = Snapshot.empty
      try save(initial)
      return initial
    }

    var snapshot = Snapshot()
    snapshot.accounts = accounts
    snapshot.categories = categories
    snapshot.transactions = transactions
    snapshot.budgets = budgets
    snapshot.recurringPayments = recurringPayments
    snapshot.savingsGoals = extras.savingsGoals
    snapshot.balanceChecks = extras.balanceChecks
    snapshot.transactionHistory = extras.transactionHistory
    snapshot.loans = extras.loans
    snapshot.investments = extras.investments
    try Ledger.validate(snapshot)
    return snapshot
  }

  /// Saves only changed entity payloads and removes rows deleted from the snapshot.
  public func save(_ state: Snapshot) throws {
    guard state.schemaVersion == Self.schemaVersion else {
      throw StoreError.unsupportedSchemaVersion(state.schemaVersion)
    }
    try Ledger.validate(state)

    try transaction {
      try syncTable("accounts", current: try rows(in: "accounts"), entities: state.accounts) {
        $0.id.uuidString
      }
      try syncTable("categories", current: try rows(in: "categories"), entities: state.categories) {
        $0.id.uuidString
      }
      try syncTable(
        "transactions", current: try rows(in: "transactions"), entities: state.transactions
      ) { $0.id.uuidString }
      try syncTable("budgets", current: try rows(in: "budgets"), entities: state.budgets) {
        $0.id.uuidString
      }
      try syncTable(
        "recurring_payments", current: try rows(in: "recurring_payments"),
        entities: state.recurringPayments
      ) { $0.id.uuidString }
      let extras = try JSONEncoder().encode(
        Extras(
          savingsGoals: state.savingsGoals, balanceChecks: state.balanceChecks,
          transactionHistory: state.transactionHistory, loans: state.loans,
          investments: state.investments))
      try setMetadata(extras, for: "extras")
      try setMetadata(Data([1]), for: "has_state")
    }
  }

  /// Creates a complete, versioned JSON backup of the current snapshot.
  public func exportBackup() throws -> Data {
    let snapshot = try load()
    let envelope = BackupEnvelope(schemaVersion: Self.schemaVersion, snapshot: snapshot)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(envelope)
    guard data.count <= Self.maximumBackupBytes else { throw StoreError.backupTooLarge }
    return data
  }

  /// Validates a backup, saves a pre-restore backup beside the database, and
  /// replaces the current state in one SQLite transaction.
  @discardableResult
  public func restoreBackup(_ data: Data) throws -> Snapshot {
    guard data.count <= Self.maximumBackupBytes else { throw StoreError.backupTooLarge }
    let envelope: BackupEnvelope
    do {
      envelope = try JSONDecoder().decode(BackupEnvelope.self, from: data)
    } catch {
      throw StoreError.invalidBackup("JSON nelze načíst: \(error.localizedDescription)")
    }
    guard (1...Self.schemaVersion).contains(envelope.schemaVersion) else {
      throw StoreError.invalidBackup("nepodporovaná verze \(envelope.schemaVersion)")
    }
    guard
      (1...Self.schemaVersion).contains(envelope.snapshot.schemaVersion)
    else {
      throw StoreError.invalidBackup("nepodporovaná verze dat \(envelope.snapshot.schemaVersion)")
    }
    guard envelope.schemaVersion == envelope.snapshot.schemaVersion else {
      throw StoreError.invalidBackup("nesouhlasí verze zálohy a dat")
    }
    var snapshot = envelope.snapshot
    if envelope.schemaVersion == 1 {
      // Version 1 had no credit-card account representation. Reject a backup
      // that smuggles those fields into a legacy payload instead of silently
      // changing its meaning during normalization.
      guard snapshot.accounts.allSatisfy({ $0.kind == .standard && $0.creditLimit == nil }) else {
        throw StoreError.invalidBackup("verze 1 obsahuje účet s podporou kreditní karty")
      }
      snapshot.schemaVersion = Self.schemaVersion
    } else if envelope.schemaVersion == 2 || envelope.schemaVersion == 3
      || envelope.schemaVersion == 4 || envelope.schemaVersion == 5
    {
      snapshot.schemaVersion = Self.schemaVersion
    }
    do {
      try Ledger.validate(snapshot)
    } catch {
      throw StoreError.invalidBackup("snapshot neprošel validací: \(error.localizedDescription)")
    }

    let currentBackup = try exportBackup()
    try writeBackup(currentBackup, name: preRestoreBackupName())
    try save(snapshot)
    return snapshot
  }

  /// Writes a timestamped backup and retains only the seven matching daily
  /// backup files in the supplied directory.
  public func dailyBackup(directory: URL, now: Date = Date()) throws {
    guard directory.isFileURL else { throw StoreError.invalidDatabaseURL }
    let data = try exportBackup()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stamp = Self.dailyTimestamp.string(from: now)
    let base = Self.safeFileStem(url.deletingPathExtension().lastPathComponent)
    let prefix = "\(base).daily-"
    let suffix = ".moneyapp-backup.json"
    var matching = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
    )
    .filter { candidate in
      let filename = candidate.lastPathComponent
      guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
      return (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }
    .sorted { $0.lastPathComponent > $1.lastPathComponent }

    let todayFiles = matching.filter {
      $0.lastPathComponent.dropFirst(prefix.count).hasPrefix(stamp + "-")
    }
    if todayFiles.isEmpty {
      let name = "\(base).daily-\(stamp)-\(UUID().uuidString).moneyapp-backup.json"
      try writeBackup(data, to: directory.appendingPathComponent(name))
      matching = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
      )
      .filter { candidate in
        let filename = candidate.lastPathComponent
        guard filename.hasPrefix(prefix), filename.hasSuffix(suffix) else { return false }
        return (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    var filesByDay: [String: [URL]] = [:]
    for file in matching {
      let suffixPart = file.lastPathComponent.dropFirst(prefix.count)
      guard let separator = suffixPart.firstIndex(of: "-") else { continue }
      let day = String(suffixPart[..<separator])
      guard day.count == 8, day.allSatisfy(\.isNumber) else { continue }
      filesByDay[day, default: []].append(file)
    }
    let days = filesByDay.keys.sorted(by: >)
    for day in days.dropFirst(Self.dailyBackupKeepCount) {
      for old in filesByDay[day, default: []] {
        try FileManager.default.removeItem(at: old)
      }
    }

    // Clean up duplicate files for a retained day as well. This handles
    // files made by older builds while keeping rotation limited to the
    // exact daily-backup naming pattern.
    for day in days.prefix(Self.dailyBackupKeepCount) {
      for duplicate in filesByDay[day, default: []].dropFirst() {
        if FileManager.default.fileExists(atPath: duplicate.path) {
          try FileManager.default.removeItem(at: duplicate)
        }
      }
    }
  }

  /// Exports transactions as a Czech, semicolon-separated CSV.
  public func exportCSV() throws -> String {
    let snapshot = try load()
    let accounts = Dictionary(uniqueKeysWithValues: snapshot.accounts.map { ($0.id, $0.name) })
    let categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
    let header = [
      "Datum", "Typ", "Účet", "Cílový účet", "Kategorie", "Částka", "Poznámka", "Rozpad",
    ].map {
      Self.csvCell($0)
    }.joined(separator: ";")
    let rows = snapshot.transactions.sorted { lhs, rhs in
      lhs.day == rhs.day ? lhs.id.uuidString < rhs.id.uuidString : lhs.day < rhs.day
    }.map { transaction in
      [
        transaction.day.rawValue,
        transaction.kind.title,
        accounts[transaction.accountID] ?? "",
        transaction.destinationAccountID.flatMap { accounts[$0] } ?? "",
        transaction.categoryID.flatMap { categories[$0] } ?? "",
        Self.formatMinorUnits(transaction.amount),
        transaction.note,
        transaction.splits?.map { split in
          "\(categories[split.categoryID] ?? ""):\(Self.formatMinorUnits(split.amount))"
        }.joined(separator: ", ") ?? "",
      ].enumerated().map { index, value in
        index == 5 ? Self.csvCell(value, sanitizeFormula: false) : Self.csvCell(value)
      }.joined(separator: ";")
    }
    return ([header] + rows).joined(separator: "\n") + "\n"
  }

  // MARK: - SQLite setup and transactions

  private static func migrate(_ db: OpaquePointer) throws {
    let version = try pragmaUserVersion(db)
    guard version >= 0 else { throw StoreError.corruptData("databáze má zápornou verzi schématu") }
    guard version <= schemaVersion else { throw StoreError.unsupportedSchemaVersion(version) }

    if version == schemaVersion {
      try validateSchema(db)
      return
    }

    if version == 1 || version == 2 {
      // Validate the complete v1 structure before changing its version. The
      // v2 model is payload-compatible, so no row rewrite is necessary.
      try validateSchema(db)
      do {
        try execute(db, "BEGIN IMMEDIATE")
        try execute(
          db,
          "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)"
        )
        try execute(
          db,
          "INSERT OR IGNORE INTO metadata(key, value) VALUES ('has_state', X'00')"
        )
        try execute(
          db,
          "INSERT OR IGNORE INTO metadata(key, value) VALUES ('extras', '{\"savingsGoals\":[],\"balanceChecks\":[],\"transactionHistory\":[],\"loans\":[],\"investments\":[]}')"
        )
        try execute(db, "PRAGMA user_version = 6")
        try execute(db, "COMMIT")
      } catch {
        do {
          try execute(db, "ROLLBACK")
        } catch let rollbackError {
          throw StoreError.transactionRollbackFailed(rollbackError.localizedDescription)
        }
        throw error
      }
      return
    }

    if version == 3 {
      try validateSchema(db)
      do {
        try execute(db, "BEGIN IMMEDIATE")
        try migrateExtrasToCurrentSchema(db)
        try execute(db, "PRAGMA user_version = 6")
        try execute(db, "COMMIT")
      } catch {
        do {
          try execute(db, "ROLLBACK")
        } catch let rollbackError {
          throw StoreError.transactionRollbackFailed(rollbackError.localizedDescription)
        }
        throw error
      }
      return
    }

    if version == 4 || version == 5 {
      // Versions 5 and 6 add optional loan links and skipped occurrences to JSON
      // payloads. Missing fields decode as nil; existing rows remain unchanged.
      // Bump the version so older apps cannot silently discard skipped dates.
      try validateSchema(db)
      do {
        try execute(db, "BEGIN IMMEDIATE")
        try execute(db, "PRAGMA user_version = 6")
        try execute(db, "COMMIT")
      } catch {
        do {
          try execute(db, "ROLLBACK")
        } catch let rollbackError {
          throw StoreError.transactionRollbackFailed(rollbackError.localizedDescription)
        }
        throw error
      }
      return
    }

    let existingTables = try userTables(db)
    guard existingTables.isEmpty else {
      throw StoreError.corruptData("databáze bez verze obsahuje neznámé tabulky")
    }

    do {
      try execute(db, "BEGIN IMMEDIATE")
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL)")
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS accounts (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS categories (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
      )
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS transactions (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL, day TEXT NOT NULL, account_id TEXT NOT NULL)"
      )
      try execute(
        db,
        "CREATE INDEX IF NOT EXISTS idx_transactions_day_account ON transactions(day, account_id)")
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS budgets (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
      try execute(
        db,
        "CREATE TABLE IF NOT EXISTS recurring_payments (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"
      )
      try execute(db, "INSERT OR IGNORE INTO metadata(key, value) VALUES ('has_state', X'00')")
      try execute(
        db,
        "INSERT OR IGNORE INTO metadata(key, value) VALUES ('extras', '{\"savingsGoals\":[],\"balanceChecks\":[],\"transactionHistory\":[],\"loans\":[],\"investments\":[]}')"
      )
      try execute(db, "PRAGMA user_version = 6")
      try execute(db, "COMMIT")
    } catch {
      do {
        try execute(db, "ROLLBACK")
      } catch let rollbackError {
        throw StoreError.transactionRollbackFailed(rollbackError.localizedDescription)
      }
      throw error
    }
  }

  private static func validateSchema(_ db: OpaquePointer) throws {
    let expected: [String: Set<String>] = [
      "metadata": ["key", "value"],
      "accounts": ["id", "payload"],
      "categories": ["id", "payload"],
      "transactions": ["id", "payload", "day", "account_id"],
      "budgets": ["id", "payload"],
      "recurring_payments": ["id", "payload"],
    ]
    for (table, columns) in expected {
      guard try userTables(db).contains(table) else {
        throw StoreError.corruptData("chybí tabulka \(table)")
      }
      let actual = try tableColumns(db, table: table)
      guard columns.isSubset(of: actual) else {
        throw StoreError.corruptData("tabulka \(table) má neplatné sloupce")
      }
    }
    guard try indexExists(db, name: "idx_transactions_day_account") else {
      throw StoreError.corruptData("chybí index transakcí")
    }
  }

  private static func migrateExtrasToCurrentSchema(_ db: OpaquePointer) throws {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(
      db, "SELECT value FROM metadata WHERE key = 'extras'", -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw sqliteError(db, "prepare extras migration")
    }
    guard let statement else { throw sqliteError(db, "prepare extras migration") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      let pointer = sqlite3_column_blob(statement, 0)
    else {
      throw StoreError.corruptData("chybí metadata extras")
    }
    let data = Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
    let legacy: LegacyExtras
    do {
      legacy = try JSONDecoder().decode(LegacyExtras.self, from: data)
    } catch {
      throw StoreError.corruptData("extras nelze migrovat: \(error.localizedDescription)")
    }
    let extras = Extras(
      savingsGoals: legacy.savingsGoals, balanceChecks: legacy.balanceChecks,
      transactionHistory: legacy.transactionHistory)
    let migrated: Data
    do {
      migrated = try JSONEncoder().encode(extras)
    } catch {
      throw StoreError.corruptData("extras nelze migrovat: \(error.localizedDescription)")
    }
    let hex = migrated.map { String(format: "%02x", $0) }.joined()
    try execute(db, "UPDATE metadata SET value = X'\(hex)' WHERE key = 'extras'")
  }

  private static func userTables(_ db: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(
      db, "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'", -1,
      &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw sqliteError(db, "prepare table query")
    }
    guard let statement else { throw sqliteError(db, "prepare table query") }
    defer { sqlite3_finalize(statement) }
    var result = Set<String>()
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { return result }
      guard step == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 0) else {
        throw sqliteError(db, "read table query")
      }
      result.insert(String(cString: pointer))
    }
  }

  private static func tableColumns(_ db: OpaquePointer, table: String) throws -> Set<String> {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw sqliteError(db, "prepare column query")
    }
    guard let statement else { throw sqliteError(db, "prepare column query") }
    defer { sqlite3_finalize(statement) }
    var result = Set<String>()
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { return result }
      guard step == SQLITE_ROW, let pointer = sqlite3_column_text(statement, 1) else {
        throw sqliteError(db, "read column query")
      }
      result.insert(String(cString: pointer))
    }
  }

  private static func indexExists(_ db: OpaquePointer, name: String) throws -> Bool {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(
      db, "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ?", -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw sqliteError(db, "prepare index query")
    }
    guard let statement else { throw sqliteError(db, "prepare index query") }
    defer { sqlite3_finalize(statement) }
    let binding = name.withCString { sqlite3_bind_text(statement, 1, $0, -1, sqliteTransient) }
    guard binding == SQLITE_OK else { throw sqliteError(db, "bind index query") }
    return sqlite3_step(statement) == SQLITE_ROW
  }

  private static func pragmaUserVersion(_ db: OpaquePointer) throws -> Int {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw sqliteError(db, "prepare user_version")
    }
    guard let statement else { throw sqliteError(db, "prepare user_version") }
    defer { sqlite3_finalize(statement) }
    let step = sqlite3_step(statement)
    guard step == SQLITE_ROW else { throw sqliteError(db, "read user_version") }
    return Int(sqlite3_column_int(statement, 0))
  }

  private static func execute(_ db: OpaquePointer, _ sql: String) throws {
    let result = sqlite3_exec(db, sql, nil, nil, nil)
    guard result == SQLITE_OK else { throw sqliteError(db, sql) }
  }

  private static func sqliteError(_ db: OpaquePointer, _ context: String) -> StoreError {
    .sqlite("\(context): \(String(cString: sqlite3_errmsg(db)))")
  }

  private func transaction<T>(_ body: () throws -> T) throws -> T {
    try Self.execute(db, "BEGIN IMMEDIATE")
    do {
      let result = try body()
      try Self.execute(db, "COMMIT")
      return result
    } catch {
      do {
        try Self.execute(db, "ROLLBACK")
      } catch let rollbackError {
        throw StoreError.transactionRollbackFailed(rollbackError.localizedDescription)
      }
      throw error
    }
  }

  // MARK: - Rows

  private func rows(in table: String) throws -> [String: Data] {
    Dictionary(uniqueKeysWithValues: try rawRows(in: table))
  }

  private func rawRows(in table: String) throws -> [(String, Data)] {
    var statement: OpaquePointer?
    // rowid preserves the user's array order for a newly-saved snapshot;
    // updates retain rowid, while newly-added entities append naturally.
    let sql = "SELECT id, payload FROM \(table) ORDER BY rowid"
    let preparation = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw Self.sqliteError(db, "prepare row query")
    }
    guard let statement else { throw Self.sqliteError(db, "prepare row query") }
    defer { sqlite3_finalize(statement) }

    var result: [(String, Data)] = []
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_DONE { break }
      guard step == SQLITE_ROW else { throw Self.sqliteError(db, "read rows") }
      guard let idPointer = sqlite3_column_text(statement, 0),
        let payloadPointer = sqlite3_column_blob(statement, 1)
      else {
        throw StoreError.corruptData("tabulka \(table) obsahuje prázdný identifikátor nebo payload")
      }
      let id = String(cString: idPointer)
      let length = Int(sqlite3_column_bytes(statement, 1))
      result.append((id, Data(bytes: payloadPointer, count: length)))
    }
    return result
  }

  private func decodeRows<T: Decodable & Identifiable>(table: String, as type: T.Type) throws -> [T]
  where T.ID == UUID {
    let decoder = JSONDecoder()
    return try rawRows(in: table).map { row in
      do {
        let value = try decoder.decode(type, from: row.1)
        guard value.id.uuidString.caseInsensitiveCompare(row.0) == .orderedSame else {
          throw StoreError.corruptData("tabulka \(table), řádek \(row.0) neodpovídá ID payloadu")
        }
        return value
      } catch {
        throw StoreError.corruptData(
          "tabulka \(table), řádek \(row.0): \(error.localizedDescription)")
      }
    }
  }

  private func syncTable<T: Encodable>(
    _ table: String, current: [String: Data], entities: [T], id: (T) -> String
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var desiredIDs: Set<String> = []
    for entity in entities {
      let key = id(entity)
      guard desiredIDs.insert(key).inserted else {
        throw StoreError.corruptData("duplicitní identifikátor \(key)")
      }
      let payload = try encoder.encode(entity)
      if current[key] != payload {
        try upsert(table: table, id: key, payload: payload, entity: entity)
      }
    }
    for key in current.keys where !desiredIDs.contains(key) {
      try delete(table: table, id: key)
    }
  }

  private func upsert<T>(table: String, id: String, payload: Data, entity: T) throws {
    let sql: String
    if table == "transactions", let transaction = entity as? Transaction {
      sql =
        "INSERT INTO transactions(id, payload, day, account_id) VALUES (?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, day=excluded.day, account_id=excluded.account_id"
      try bindAndRun(
        sql: sql,
        bindings: { statement in
          try bindText(statement, index: 1, value: id)
          try bindData(statement, index: 2, value: payload)
          try bindText(statement, index: 3, value: transaction.day.rawValue)
          try bindText(statement, index: 4, value: transaction.accountID.uuidString)
        })
    } else {
      sql =
        "INSERT INTO \(table)(id, payload) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload"
      try bindAndRun(
        sql: sql,
        bindings: { statement in
          try bindText(statement, index: 1, value: id)
          try bindData(statement, index: 2, value: payload)
        })
    }
  }

  private func delete(table: String, id: String) throws {
    try bindAndRun(
      sql: "DELETE FROM \(table) WHERE id = ?",
      bindings: { statement in
        try bindText(statement, index: 1, value: id)
      })
  }

  private func bindAndRun(sql: String, bindings: (OpaquePointer) throws -> Void) throws {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw Self.sqliteError(db, "prepare mutation")
    }
    guard let statement else { throw Self.sqliteError(db, "prepare mutation") }
    defer { sqlite3_finalize(statement) }
    try bindings(statement)
    guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.sqliteError(db, "run mutation") }
  }

  private func bindText(_ statement: OpaquePointer, index: Int32, value: String) throws {
    let result = value.withCString {
      sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
    }
    guard result == SQLITE_OK else { throw Self.sqliteError(db, "bind text") }
  }

  private func bindData(_ statement: OpaquePointer, index: Int32, value: Data) throws {
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement, index, bytes.baseAddress, Int32(value.count), Self.sqliteTransient)
    }
    guard result == SQLITE_OK else { throw Self.sqliteError(db, "bind blob") }
  }

  private func metadataValue(for key: String) throws -> Data? {
    var statement: OpaquePointer?
    let preparation = sqlite3_prepare_v2(
      db, "SELECT value FROM metadata WHERE key = ?", -1, &statement, nil)
    guard preparation == SQLITE_OK else {
      if let statement { sqlite3_finalize(statement) }
      throw Self.sqliteError(db, "prepare metadata query")
    }
    guard let statement else { throw Self.sqliteError(db, "prepare metadata query") }
    defer { sqlite3_finalize(statement) }
    try bindText(statement, index: 1, value: key)
    let step = sqlite3_step(statement)
    if step == SQLITE_DONE { return nil }
    guard step == SQLITE_ROW else { throw Self.sqliteError(db, "read metadata") }
    guard let pointer = sqlite3_column_blob(statement, 0) else {
      throw StoreError.corruptData("metadata \(key)")
    }
    return Data(bytes: pointer, count: Int(sqlite3_column_bytes(statement, 0)))
  }

  private func setMetadata(_ value: Data, for key: String) throws {
    try bindAndRun(
      sql:
        "INSERT INTO metadata(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
      bindings: { statement in
        try bindText(statement, index: 1, value: key)
        try bindData(statement, index: 2, value: value)
      })
  }

  // MARK: - Backup files and CSV

  private func preRestoreBackupName() -> String {
    let stem = Self.safeFileStem(url.deletingPathExtension().lastPathComponent)
    let stamp = Self.backupTimestamp.string(from: Date())
    return "\(stem).pre-restore-\(stamp)-\(UUID().uuidString).moneyapp-backup.json"
  }

  private func writeBackup(_ data: Data, name: String) throws {
    try writeBackup(data, to: url.deletingLastPathComponent().appendingPathComponent(name))
  }

  private func writeBackup(_ data: Data, to destination: URL) throws {
    guard data.count <= Self.maximumBackupBytes else { throw StoreError.backupTooLarge }
    try FileManager.default.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    do { try data.write(to: destination, options: [.atomic]) } catch {
      throw StoreError.sqlite("zápis zálohy selhal: \(error.localizedDescription)")
    }
  }

  private static func safeFileStem(_ value: String) -> String {
    let allowed = value.unicodeScalars.map { scalar -> Character in
      if CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_" {
        return Character(String(scalar))
      }
      return "_"
    }
    let stem = String(allowed)
    return stem.isEmpty ? "moneyapp" : stem
  }

  private static let backupTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return formatter
  }()

  private static let dailyTimestamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyyMMdd"
    return formatter
  }()

  private static func csvCell(_ value: String, sanitizeFormula: Bool = true) -> String {
    let safe: String
    if sanitizeFormula, let first = value.first(where: { !$0.isWhitespace }), "=+-@".contains(first)
    {
      safe = "'" + value
    } else {
      safe = value
    }
    let escaped = safe.replacingOccurrences(of: "\"", with: "\"\"")
    if escaped.contains(";") || escaped.contains("\n") || escaped.contains("\r")
      || escaped.contains("\"")
    {
      return "\"\(escaped)\""
    }
    return escaped
  }

  private static func formatMinorUnits(_ amount: Int64) -> String {
    Money.format(amount)
      .replacingOccurrences(of: " Kč", with: "")
      .replacingOccurrences(of: " ", with: "")
  }
}
