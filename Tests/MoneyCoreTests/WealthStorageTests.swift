import CSQLite
import Foundation
import XCTest

@testable import MoneyCore

final class WealthStorageTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MoneyCoreWealthTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testWealthRoundTripsThroughSQLiteAndBackup() async throws {
    let url = directory.appendingPathComponent("wealth.sqlite")
    var snapshot = Snapshot()
    snapshot.loans = [
      Loan(
        name: "Půjčka", direction: .lent, principal: 80_000, startDay: Day(rawValue: "2024-01-01"),
        installments: [
          LoanInstallment(
            amount: 20_000, dueDay: Day(rawValue: "2024-02-01"),
            paidDay: Day(rawValue: "2024-02-01"))
        ])
    ]
    snapshot.investments = [
      InvestmentPortfolio(
        name: "ETF",
        entries: [
          InvestmentEntry(kind: .deposit, amount: 100_000, day: Day(rawValue: "2024-01-01"))
        ], currentValue: 110_000, valuedOn: Day(rawValue: "2024-12-31"))
    ]

    let store = try SQLiteStore(url: url)
    try await store.save(snapshot)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, snapshot)
    let backup = try await store.exportBackup()
    let restored = try await store.restoreBackup(backup)
    XCTAssertEqual(restored, snapshot)
  }

  func testLegacySchema3DatabaseDefaultsWealthWithoutDroppingExtras() async throws {
    let url = directory.appendingPathComponent("legacy.sqlite")
    var snapshot = Snapshot()
    snapshot.savingsGoals = [SavingsGoal(name: "Rezerva", target: 100_000, saved: 20_000)]
    let account = makeAccount()
    let category = Category(
      id: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!, name: "Jídlo")
    let transaction = Transaction(
      id: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!, kind: .income,
      amount: 50_000, day: Day(rawValue: "2024-01-02"), accountID: account.id,
      categoryID: category.id)
    snapshot.accounts = [account]
    snapshot.categories = [category]
    snapshot.transactions = [transaction]
    snapshot.transactionHistory = [TransactionChange(before: nil, after: transaction)]
    snapshot.balanceChecks = [
      BalanceCheck(
        accountID: account.id, day: Day(rawValue: "2024-01-01"), balance: 10_000)
    ]
    do {
      let store = try SQLiteStore(url: url)
      try await store.save(snapshot)
    }
    try writeLegacyExtras(snapshot, at: url)
    try execute("PRAGMA user_version = 3", at: url)

    let migrated = try SQLiteStore(url: url)
    let loaded = try await migrated.load()
    XCTAssertEqual(loaded.schemaVersion, 6)
    XCTAssertEqual(loaded.savingsGoals, snapshot.savingsGoals)
    XCTAssertEqual(loaded.balanceChecks, snapshot.balanceChecks)
    XCTAssertEqual(loaded.transactions, snapshot.transactions)
    XCTAssertEqual(loaded.transactionHistory, snapshot.transactionHistory)
    XCTAssertNil(loaded.transactions[0].isSalary)
    XCTAssertEqual(loaded.loans, [])
    XCTAssertEqual(loaded.investments, [])
  }

  func testLegacySchema3BackupDefaultsWealth() async throws {
    let store = try SQLiteStore(url: directory.appendingPathComponent("backup.sqlite"))
    try await store.save(Snapshot())
    let data = try await store.exportBackup()
    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
    envelope["schemaVersion"] = 3
    snapshot["schemaVersion"] = 3
    snapshot.removeValue(forKey: "loans")
    snapshot.removeValue(forKey: "investments")
    envelope["snapshot"] = snapshot

    let restored = try await store.restoreBackup(
      JSONSerialization.data(withJSONObject: envelope))
    XCTAssertEqual(restored.schemaVersion, 6)
    XCTAssertEqual(restored.loans, [])
    XCTAssertEqual(restored.investments, [])
  }

  func testCurrentBackupMissingWealthFieldsIsRejected() async throws {
    let store = try SQLiteStore(url: directory.appendingPathComponent("strict.sqlite"))
    try await store.save(Snapshot())
    let original = try await store.load()
    let data = try await store.exportBackup()
    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var snapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
    snapshot.removeValue(forKey: "loans")
    envelope["snapshot"] = snapshot
    do {
      _ = try await store.restoreBackup(JSONSerialization.data(withJSONObject: envelope))
      XCTFail("Aktuální záloha bez nových polí musí být odmítnuta")
    } catch {}
    let after = try await store.load()
    XCTAssertEqual(after, original)
  }

  private struct LegacyExtras: Codable {
    let savingsGoals: [SavingsGoal]
    let balanceChecks: [BalanceCheck]
    let transactionHistory: [TransactionChange]
  }

  private func makeAccount() -> Account {
    Account(
      id: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!, name: "Účet",
      openingBalance: 10_000, openingDay: Day(rawValue: "2024-01-01"))
  }

  private func writeLegacyExtras(_ snapshot: Snapshot, at url: URL) throws {
    let data = try JSONEncoder().encode(
      LegacyExtras(
        savingsGoals: snapshot.savingsGoals, balanceChecks: snapshot.balanceChecks,
        transactionHistory: snapshot.transactionHistory))
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else { throw NSError(domain: "WealthStorageTests", code: 1) }
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        database, "UPDATE metadata SET value = ? WHERE key = 'extras'", -1, &statement, nil
      ) == SQLITE_OK, let statement
    else { throw NSError(domain: "WealthStorageTests", code: 2) }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let result = data.withUnsafeBytes { bytes in
      sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(data.count), transient)
    }
    guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {
      throw NSError(domain: "WealthStorageTests", code: 3)
    }
  }

  private func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else { throw NSError(domain: "WealthStorageTests", code: 4) }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "WealthStorageTests", code: 5)
    }
  }
}
