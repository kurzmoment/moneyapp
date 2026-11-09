import CSQLite
import Foundation
import XCTest

@testable import MoneyCore

final class StorageTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MoneyCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testRoundTripPersistsEveryEntityAndCanBeReopened() async throws {
    let database = directory.appendingPathComponent("ledger.sqlite")
    let original = makeSnapshot()

    do {
      let store = try SQLiteStore(url: database)
      try await store.save(original)
      let loaded = try await store.load()
      XCTAssertEqual(loaded, original)
    }

    let reopened = try SQLiteStore(url: database)
    let loaded = try await reopened.load()
    XCTAssertEqual(loaded, original)
  }

  func testRestoreCreatesPreRestoreBackupAndInvalidBackupLeavesStateUntouched() async throws {
    let database = directory.appendingPathComponent("ledger.sqlite")
    let store = try SQLiteStore(url: database)
    let original = makeSnapshot()
    try await store.save(original)
    let backup = try await store.exportBackup()

    var changed = original
    changed.accounts[0].name = "Změněný účet"
    try await store.save(changed)

    do {
      _ = try await store.restoreBackup(Data("not-json".utf8))
      XCTFail("Neplatná záloha musí být odmítnuta")
    } catch {
      let loaded = try await store.load()
      XCTAssertEqual(loaded, changed)
    }

    let restored = try await store.restoreBackup(backup)
    XCTAssertEqual(restored, original)
    let preRestoreBackups = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.lastPathComponent.contains(".pre-restore-") }
    XCTAssertEqual(preRestoreBackups.count, 1)
  }

  func testCSVUsesCzechColumnsEscapesCellsAndSanitizesFormulaText() async throws {
    let database = directory.appendingPathComponent("ledger.sqlite")
    let store = try SQLiteStore(url: database)
    var snapshot = makeSnapshot()
    snapshot.transactions[0].note = "=SUM(A1:A2); \"poznámka\""
    try await store.save(snapshot)

    let csv = try await store.exportCSV()
    XCTAssertTrue(csv.hasPrefix("Datum;Typ;Účet;Cílový účet;Kategorie;Částka;Poznámka;Rozpad\n"))
    XCTAssertTrue(csv.contains("'=SUM(A1:A2); \"\"poznámka\"\""))
    XCTAssertTrue(csv.contains(";12,34;"))
  }

  func testDailyBackupRetainsSevenMatchingFiles() async throws {
    let database = directory.appendingPathComponent("ledger.sqlite")
    let backupDirectory = directory.appendingPathComponent("backups", isDirectory: true)
    let store = try SQLiteStore(url: database)
    try await store.save(makeSnapshot())

    let start = Date(timeIntervalSince1970: 1_700_000_000)
    for offset in 0..<8 {
      try await store.dailyBackup(
        directory: backupDirectory, now: start.addingTimeInterval(Double(offset) * 86_400))
      if offset == 7 {
        try await store.dailyBackup(
          directory: backupDirectory, now: start.addingTimeInterval(Double(offset) * 86_400 + 3_600)
        )
      }
    }

    let files = try FileManager.default.contentsOfDirectory(
      at: backupDirectory, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.filter { $0.lastPathComponent.contains(".daily-") }.count, 7)
  }

  func testFirstLoadPersistsDefaultCategoriesAndIsStable() async throws {
    let store = try SQLiteStore(url: directory.appendingPathComponent("fresh.sqlite"))

    let first = try await store.load()
    let second = try await store.load()

    XCTAssertFalse(first.categories.isEmpty)
    XCTAssertEqual(first, second)
  }

  func testJSONValidBackupWithOrphanTransactionIsRejectedAndPreservesState() async throws {
    let database = directory.appendingPathComponent("ledger.sqlite")
    let store = try SQLiteStore(url: database)
    let original = makeSnapshot()
    try await store.save(original)
    let backup = try await store.exportBackup()

    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    var snapshot = try XCTUnwrap(root["snapshot"] as? [String: Any])
    var transactions = try XCTUnwrap(snapshot["transactions"] as? [[String: Any]])
    transactions[0]["accountID"] = UUID().uuidString
    snapshot["transactions"] = transactions
    root["snapshot"] = snapshot
    let malformed = try JSONSerialization.data(withJSONObject: root)

    do {
      _ = try await store.restoreBackup(malformed)
      XCTFail("Neplatná záloha musí být odmítnuta")
    } catch {}
    let loaded = try await store.load()
    XCTAssertEqual(loaded, original)
  }

  func testFutureSchemaVersionIsRejected() async throws {
    let database = directory.appendingPathComponent("future.sqlite")
    try executeSQLite("PRAGMA user_version = 99", at: database)

    XCTAssertThrowsError(try SQLiteStore(url: database))
  }

  func testCorruptRowIdentityOrPayloadIsRejected() async throws {
    let original = makeSnapshot()

    let identityDatabase = directory.appendingPathComponent("bad-id.sqlite")
    let identityStore = try SQLiteStore(url: identityDatabase)
    try await identityStore.save(original)
    try executeSQLite(
      "UPDATE accounts SET id = '00000000-0000-0000-0000-000000000099' WHERE id = '00000000-0000-0000-0000-000000000001'",
      at: identityDatabase)
    do {
      _ = try await identityStore.load()
      XCTFail("Neplatné ID řádku musí být odmítnuto")
    } catch {}

    let payloadDatabase = directory.appendingPathComponent("bad-payload.sqlite")
    let payloadStore = try SQLiteStore(url: payloadDatabase)
    try await payloadStore.save(original)
    try executeSQLite("UPDATE accounts SET payload = X'7B'", at: payloadDatabase)
    do {
      _ = try await payloadStore.load()
      XCTFail("Poškozený payload musí být odmítnut")
    } catch {}
  }

  func testSaveFailureRollsBackAllEntityChanges() async throws {
    let database = directory.appendingPathComponent("rollback.sqlite")
    let store = try SQLiteStore(url: database)
    let original = makeSnapshot()
    try await store.save(original)
    try executeSQLite(
      "CREATE TRIGGER fail_category_update BEFORE UPDATE ON categories BEGIN SELECT RAISE(ABORT, 'test failure'); END",
      at: database)

    var changed = original
    changed.accounts[0].name = "Neuložitelná změna"
    changed.categories[0].name = "Selže až po zápisu změny účtu"
    do {
      try await store.save(changed)
      XCTFail("Selhání triggeru musí vyvolat rollback")
    } catch {}

    let loaded = try await store.load()
    XCTAssertEqual(loaded, original)
  }

  func testMissingInitializationMarkerDoesNotSilentlyResetEmptyData() async throws {
    let database = directory.appendingPathComponent("missing-marker.sqlite")
    let store = try SQLiteStore(url: database)
    try await store.save(Snapshot())
    try executeSQLite("DELETE FROM metadata WHERE key = 'has_state'", at: database)
    do {
      _ = try await store.load()
      XCTFail("Poškozená metadata nesmějí znovu vytvořit výchozí data")
    } catch {}
  }

  func testLegacyV1DatabaseMigratesWithoutRewritingAccountPayloads() async throws {
    let database = directory.appendingPathComponent("legacy.sqlite")
    let original = makeSnapshot()
    do {
      let store = try SQLiteStore(url: database)
      try await store.save(original)
      let accountPayload = try JSONEncoder().encode(original.accounts[0])
      var accountObject = try XCTUnwrap(
        JSONSerialization.jsonObject(with: accountPayload) as? [String: Any])
      accountObject.removeValue(forKey: "kind")
      accountObject.removeValue(forKey: "creditLimit")
      let legacyPayload = try JSONSerialization.data(withJSONObject: accountObject)
      try updateAccountPayload(legacyPayload, id: original.accounts[0].id, at: database)
      try executeSQLite("PRAGMA user_version = 1", at: database)
    }

    let reopened = try SQLiteStore(url: database)
    let loaded = try await reopened.load()
    XCTAssertEqual(loaded, original)
  }

  func testLegacyV1BackupIsNormalizedTo5() async throws {
    let database = directory.appendingPathComponent("legacy-backup.sqlite")
    let store = try SQLiteStore(url: database)
    let original = makeSnapshot()
    try await store.save(original)
    let current = try await store.exportBackup()
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
    root["schemaVersion"] = 1
    var snapshot = try XCTUnwrap(root["snapshot"] as? [String: Any])
    snapshot["schemaVersion"] = 1
    var accounts = try XCTUnwrap(snapshot["accounts"] as? [[String: Any]])
    for index in accounts.indices {
      accounts[index].removeValue(forKey: "kind")
      accounts[index].removeValue(forKey: "creditLimit")
    }
    snapshot["accounts"] = accounts
    root["snapshot"] = snapshot

    let restored = try await store.restoreBackup(JSONSerialization.data(withJSONObject: root))
    XCTAssertEqual(restored.schemaVersion, 6)
    XCTAssertEqual(restored, original)
  }

  func testCreditCardFieldsRoundTripThroughBackup() async throws {
    let database = directory.appendingPathComponent("credit-card.sqlite")
    let store = try SQLiteStore(url: database)
    var original = makeSnapshot()
    original.accounts[0].kind = .creditCard
    original.accounts[0].creditLimit = 250_000
    try await store.save(original)

    let backup = try await store.exportBackup()
    let restored = try await store.restoreBackup(backup)
    XCTAssertEqual(restored.accounts[0].kind, .creditCard)
    XCTAssertEqual(restored.accounts[0].creditLimit, 250_000)
    XCTAssertEqual(restored, original)
  }

  func testBackupVersionMismatchAndFutureVersionAreRejected() async throws {
    let database = directory.appendingPathComponent("backup-versions.sqlite")
    let store = try SQLiteStore(url: database)
    try await store.save(makeSnapshot())
    let backup = try await store.exportBackup()
    var root = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    var snapshot = try XCTUnwrap(root["snapshot"] as? [String: Any])
    snapshot["schemaVersion"] = 1
    root["snapshot"] = snapshot
    do {
      _ = try await store.restoreBackup(JSONSerialization.data(withJSONObject: root))
      XCTFail("Nesouhlasící verze musí být odmítnuta")
    } catch {}

    root["schemaVersion"] = 99
    snapshot["schemaVersion"] = 99
    root["snapshot"] = snapshot
    do {
      _ = try await store.restoreBackup(JSONSerialization.data(withJSONObject: root))
      XCTFail("Budoucí verze musí být odmítnuta")
    } catch {}
  }

  private func makeSnapshot() -> Snapshot {
    let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let destinationID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let recurringID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let transactionID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    let budgetID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!

    var snapshot = Snapshot()
    snapshot.accounts = [
      Account(
        id: accountID, name: "Běžný účet", openingBalance: 100_00,
        openingDay: Day(rawValue: "2024-01-01")),
      Account(
        id: destinationID, name: "Spoření", openingBalance: 0,
        openingDay: Day(rawValue: "2024-01-01")),
    ]
    snapshot.categories = [Category(id: categoryID, name: "Jídlo", symbol: "fork.knife")]
    snapshot.transactions = [
      Transaction(
        id: transactionID,
        kind: .expense,
        amount: 1234,
        day: Day(rawValue: "2024-02-03"),
        accountID: accountID,
        categoryID: categoryID,
        note: "Oběd"
      )
    ]
    snapshot.budgets = [
      Budget(id: budgetID, categoryID: categoryID, month: "2024-02", limit: 20_000)
    ]
    snapshot.recurringPayments = [
      RecurringPayment(
        id: recurringID,
        name: "Předplatné",
        amount: 999,
        accountID: accountID,
        categoryID: categoryID,
        startDay: Day(rawValue: "2024-01-15"),
        interval: .monthly
      )
    ]
    return snapshot
  }

  private func executeSQLite(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
    guard openResult == SQLITE_OK, let database else {
      throw NSError(
        domain: "StorageTests", code: Int(openResult),
        userInfo: [NSLocalizedDescriptionKey: "SQLite open failed"])
    }
    defer { sqlite3_close(database) }

    let result = sqlite3_exec(database, sql, nil, nil, nil)
    guard result == SQLITE_OK else {
      throw NSError(
        domain: "StorageTests",
        code: Int(result),
        userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(database))]
      )
    }
  }

  private func updateAccountPayload(_ payload: Data, id: UUID, at url: URL) throws {
    var database: OpaquePointer?
    let openResult = sqlite3_open_v2(
      url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    guard openResult == SQLITE_OK, let database else {
      throw NSError(domain: "StorageTests", code: Int(openResult))
    }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "UPDATE accounts SET payload = ? WHERE id = ?", -1, &statement, nil) == SQLITE_OK,
      let statement
    else { throw NSError(domain: "StorageTests", code: 1) }
    defer { sqlite3_finalize(statement) }
    let payloadResult = payload.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(payload.count), nil)
    }
    guard payloadResult == SQLITE_OK else { throw NSError(domain: "StorageTests", code: 2) }
    let idResult = id.uuidString.withCString {
      sqlite3_bind_text(statement, 2, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
    guard idResult == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "StorageTests", code: 3)
    }
  }
}
