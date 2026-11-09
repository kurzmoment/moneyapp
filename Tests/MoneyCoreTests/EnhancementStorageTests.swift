import CSQLite
import Foundation
import XCTest

@testable import MoneyCore

final class EnhancementStorageTests: XCTestCase {
  private var directory: URL!
  private let accountID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let account2ID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
  private let categoryID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
  private let category2ID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MoneyCoreEnhancementTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func baseSnapshot() -> Snapshot {
    var snapshot = Snapshot()
    snapshot.accounts = [
      Account(
        id: accountID, name: "Běžný", openingBalance: 100_000,
        openingDay: Day(rawValue: "2024-01-01")),
      Account(
        id: account2ID, name: "Spoření", openingBalance: 20_000,
        openingDay: Day(rawValue: "2024-01-01")),
    ]
    snapshot.categories = [
      Category(id: categoryID, name: "Jídlo"),
      Category(id: category2ID, name: "Domácnost"),
    ]
    return snapshot
  }

  private func execute(_ sql: String, at url: URL) throws {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == 0, let db else { throw NSError(domain: "SQLite", code: 1) }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, sql, nil, nil, nil) == 0 else {
      throw NSError(domain: "SQLite", code: 2)
    }
  }

  func testSchema2DatabaseMigratesTo5WithoutDataLoss() async throws {
    let url = directory.appendingPathComponent("migration.sqlite")
    let original = baseSnapshot()
    let store = try SQLiteStore(url: url)
    try await store.save(original)
    try execute("DELETE FROM metadata WHERE key = 'extras'", at: url)
    try execute("PRAGMA user_version = 2", at: url)

    let reopened = try SQLiteStore(url: url)
    let loaded = try await reopened.load()
    XCTAssertEqual(loaded.schemaVersion, 6)
    XCTAssertEqual(loaded.accounts, original.accounts)
    XCTAssertEqual(loaded.categories, original.categories)
    XCTAssertEqual(loaded.transactions, original.transactions)
  }

  func testSchema2BackupIsNormalizedTo5() async throws {
    let url = directory.appendingPathComponent("backup.sqlite")
    let store = try SQLiteStore(url: url)
    let original = baseSnapshot()
    try await store.save(original)
    let backup = try await store.exportBackup()
    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: backup) as? [String: Any])
    object["schemaVersion"] = 2
    var snapshot = try XCTUnwrap(object["snapshot"] as? [String: Any])
    snapshot["schemaVersion"] = 2
    snapshot.removeValue(forKey: "savingsGoals")
    snapshot.removeValue(forKey: "balanceChecks")
    snapshot.removeValue(forKey: "transactionHistory")
    object["snapshot"] = snapshot

    let restored = try await store.restoreBackup(try JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(restored.schemaVersion, 6)
    XCTAssertEqual(restored.accounts, original.accounts)
    XCTAssertEqual(restored.savingsGoals, [])
  }

  func testExtrasAndSplitsRoundTripThroughSQLiteAndBackup() async throws {
    let url = directory.appendingPathComponent("extras.sqlite")
    let store = try SQLiteStore(url: url)
    var snapshot = baseSnapshot()
    snapshot.transactions = [
      Transaction(
        kind: .expense, amount: 3_000, day: Day(rawValue: "2024-02-01"), accountID: accountID,
        splits: [
          TransactionSplit(categoryID: categoryID, amount: 1_000),
          TransactionSplit(categoryID: category2ID, amount: 2_000),
        ])
    ]
    snapshot.savingsGoals = [SavingsGoal(name: "Dovolená", target: 100_000, saved: 25_000)]
    snapshot.balanceChecks = [
      BalanceCheck(accountID: accountID, day: Day(rawValue: "2024-02-01"), balance: 97_000)
    ]
    snapshot.transactionHistory = [
      TransactionChange(before: nil, after: snapshot.transactions[0])
    ]
    try await store.save(snapshot)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, snapshot)
    let backup = try await store.exportBackup()
    let restored = try await store.restoreBackup(backup)
    XCTAssertEqual(restored, snapshot)
    let reloaded = try await store.load()
    XCTAssertEqual(reloaded, snapshot)
  }

  func testInvalidSplitsAndNonExpenseSplitsAreRejected() {
    var snapshot = baseSnapshot()
    let split = TransactionSplit(categoryID: categoryID, amount: 1_000)
    snapshot.transactions = [
      Transaction(
        kind: .expense, amount: 2_000, day: Day(rawValue: "2024-02-01"), accountID: accountID,
        splits: [split, split])
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))

    snapshot.transactions[0].splits = [
      TransactionSplit(categoryID: categoryID, amount: 500),
      TransactionSplit(categoryID: category2ID, amount: 1000),
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))
    snapshot.transactions[0].splits = [
      TransactionSplit(categoryID: categoryID, amount: -500),
      TransactionSplit(categoryID: category2ID, amount: 2500),
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))

    snapshot.transactions = [
      Transaction(
        kind: .income, amount: 2_000, day: Day(rawValue: "2024-02-01"), accountID: accountID,
        categoryID: categoryID,
        splits: [
          TransactionSplit(categoryID: categoryID, amount: 1_000),
          TransactionSplit(categoryID: category2ID, amount: 1_000),
        ])
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))
  }

  func testGoalsAndChecksRejectInvalidAmountsOrReferences() {
    var snapshot = baseSnapshot()
    snapshot.savingsGoals = [SavingsGoal(name: "Cíl", target: -1, saved: 0)]
    XCTAssertThrowsError(try Ledger.validate(snapshot))
    snapshot.savingsGoals = []
    snapshot.balanceChecks = [
      BalanceCheck(accountID: UUID(), day: Day(rawValue: "2024-02-01"), balance: 1)
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))
  }
  func testIncompleteVersion3BackupIsRejectedWithoutDroppingData() async throws {
    let store = try SQLiteStore(url: directory.appendingPathComponent("incomplete.sqlite"))
    var original = baseSnapshot()
    original.savingsGoals = [SavingsGoal(name: "Rezerva", target: 1000, saved: 200)]
    try await store.save(original)
    let data = try await store.exportBackup()
    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
    snapshot.removeValue(forKey: "savingsGoals")
    envelope["snapshot"] = snapshot
    do {
      _ = try await store.restoreBackup(JSONSerialization.data(withJSONObject: envelope))
      XCTFail("Incomplete backup should fail")
    } catch {}
    let actual = try await store.load()
    XCTAssertEqual(actual, original)
  }

}
