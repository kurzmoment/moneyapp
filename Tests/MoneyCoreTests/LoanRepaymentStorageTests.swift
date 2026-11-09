import CSQLite
import Foundation
import XCTest

@testable import MoneyCore

final class LoanRepaymentStorageTests: XCTestCase {
  private var directory: URL!

  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("MoneyCoreLoanRepaymentTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  func testLegacySchema4MigrationPreservesLoansAndLeavesLinksNil() async throws {
    let url = directory.appendingPathComponent("legacy4.sqlite")
    let account = Account(
      name: "Banka", openingBalance: 100_000, openingDay: Day(rawValue: "2024-01-01"))
    let category = Category(name: "Splátky")
    let loan = Loan(
      name: "Půjčka", direction: .borrowed, principal: 50_000,
      startDay: Day(rawValue: "2024-01-01"),
      installments: [
        LoanInstallment(amount: 10_000, dueDay: Day(rawValue: "2024-02-01"))
      ])
    let recurring = RecurringPayment(
      name: "Splátka", amount: 10_000, accountID: account.id, categoryID: category.id,
      startDay: Day(rawValue: "2024-02-01"), interval: .monthly)
    let transaction = Transaction(
      kind: .expense, amount: 10_000, day: Day(rawValue: "2024-02-01"), accountID: account.id,
      categoryID: category.id)
    var snapshot = Snapshot()
    snapshot.accounts = [account]
    snapshot.categories = [category]
    snapshot.loans = [loan]
    snapshot.recurringPayments = [recurring]
    snapshot.transactions = [transaction]

    let store = try SQLiteStore(url: url)
    try await store.save(snapshot)
    try execute("PRAGMA user_version = 4", at: url)

    let migrated = try SQLiteStore(url: url)
    let loaded = try await migrated.load()
    XCTAssertEqual(loaded.schemaVersion, 6)
    XCTAssertEqual(loaded.loans, snapshot.loans)
    XCTAssertEqual(loaded.recurringPayments, snapshot.recurringPayments)
    XCTAssertEqual(loaded.transactions, snapshot.transactions)
    XCTAssertNil(loaded.recurringPayments[0].loanID)
    XCTAssertNil(loaded.transactions[0].loanID)

    let backupData = try await migrated.exportBackup()
    var legacyBackup = try XCTUnwrap(
      JSONSerialization.jsonObject(with: backupData) as? [String: Any])
    legacyBackup["schemaVersion"] = 4
    var backupSnapshot = try XCTUnwrap(legacyBackup["snapshot"] as? [String: Any])
    backupSnapshot["schemaVersion"] = 4
    legacyBackup["snapshot"] = backupSnapshot
    let restored = try await migrated.restoreBackup(
      try JSONSerialization.data(withJSONObject: legacyBackup))
    XCTAssertEqual(restored.schemaVersion, 6)
    XCTAssertNil(restored.recurringPayments[0].loanID)
    XCTAssertNil(restored.transactions[0].loanID)
  }

  func testLinkedRepaymentAndConfirmedTransactionRoundTripThroughStoreAndBackup() async throws {
    let url = directory.appendingPathComponent("linked.sqlite")
    let account = Account(
      name: "Banka", openingBalance: 100_000, openingDay: Day(rawValue: "2024-01-01"))
    let category = Category(name: "Splátky")
    let installment = LoanInstallment(
      amount: 10_000, dueDay: Day(rawValue: "2024-01-15"), paidDay: Day(rawValue: "2024-01-15"))
    let loan = Loan(
      name: "Půjčka", direction: .borrowed, principal: 50_000,
      startDay: Day(rawValue: "2024-01-01"), installments: [installment])
    let recurring = RecurringPayment(
      name: "Splátka", amount: 10_000, accountID: account.id, categoryID: category.id,
      startDay: Day(rawValue: "2024-02-01"), interval: .monthly, loanID: loan.id)
    let transaction = Transaction(
      kind: .expense, amount: 10_000, day: Day(rawValue: "2024-02-01"), accountID: account.id,
      categoryID: category.id, recurringID: recurring.id, occurrenceDay: recurring.startDay,
      loanID: loan.id)
    var snapshot = Snapshot()
    snapshot.accounts = [account]
    snapshot.categories = [category]
    snapshot.loans = [loan]
    snapshot.recurringPayments = [recurring]
    snapshot.transactions = [transaction]

    let store = try SQLiteStore(url: url)
    try await store.save(snapshot)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loaded.loans[0], in: loaded), 30_000)

    let restored = try await store.restoreBackup(try await store.exportBackup())
    XCTAssertEqual(restored, snapshot)
    XCTAssertEqual(restored.recurringPayments[0].loanID, loan.id)
    XCTAssertEqual(restored.transactions[0].loanID, loan.id)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: restored.loans[0], in: restored), 30_000)
  }

  func testManualReceiptSurvivesStorageAndBackup() async throws {
    var snapshot = Snapshot()
    let day = Day(rawValue: "2024-01-01")
    let account = Account(name: "Banka", openingBalance: 0, openingDay: day)
    let loan = Loan(name: "Vrácení", direction: .lent, principal: 10_000, startDay: day)
    snapshot.accounts = [account]
    snapshot.loans = [loan]
    try Ledger.receiveLoanRepayment(
      loanID: loan.id, receiptID: UUID(), accountID: account.id, amount: 1_234,
      paidOn: day, in: &snapshot)
    let store = try SQLiteStore(url: directory.appendingPathComponent("receipt.sqlite"))
    try await store.save(snapshot)
    let loaded = try await store.load()
    XCTAssertEqual(loaded, snapshot)
    let restored = try await store.restoreBackup(try await store.exportBackup())
    XCTAssertEqual(restored, snapshot)
    XCTAssertEqual(try Ledger.balance(account: account, in: restored), 1_234)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: restored.loans[0], in: restored), 8_766)
  }

  func testSchema5MigrationAndSkippedOccurrenceRoundTrip() async throws {
    let url = directory.appendingPathComponent("skipped.sqlite")
    let day = Day(rawValue: "2024-01-31")
    let account = Account(
      name: "Banka", openingBalance: 100_000, openingDay: Day(rawValue: "2024-01-01"))
    let category = Category(name: "Poplatky")
    let payment = RecurringPayment(
      name: "Televize", amount: 15_00, accountID: account.id, categoryID: category.id,
      startDay: day, interval: .monthly)
    var snapshot = Snapshot()
    snapshot.accounts = [account]
    snapshot.categories = [category]
    snapshot.recurringPayments = [payment]
    let store = try SQLiteStore(url: url)
    try await store.save(snapshot)
    try execute("PRAGMA user_version = 5", at: url)
    let migrated = try SQLiteStore(url: url)
    let loaded = try await migrated.load()
    XCTAssertEqual(loaded, snapshot)
    XCTAssertNil(loaded.recurringPayments[0].skippedOccurrences)

    let oldBackup = try await migrated.exportBackup()
    var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: oldBackup) as? [String: Any])
    envelope["schemaVersion"] = 5
    var oldSnapshot = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
    oldSnapshot["schemaVersion"] = 5
    envelope["snapshot"] = oldSnapshot
    let restoredOld = try await migrated.restoreBackup(
      JSONSerialization.data(withJSONObject: envelope))
    XCTAssertEqual(restoredOld, snapshot)

    try Ledger.skipMonthlyPayment(paymentID: payment.id, occurrence: day, in: &snapshot)
    try await migrated.save(snapshot)
    let reopened = try SQLiteStore(url: url)
    let persisted = try await reopened.load()
    XCTAssertEqual(persisted, snapshot)
    let restored = try await reopened.restoreBackup(try await reopened.exportBackup())
    XCTAssertEqual(restored, snapshot)
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: restored.recurringPayments[0], in: restored),
      Day(rawValue: "2024-02-29"))
    XCTAssertEqual(try Ledger.balance(account: account, in: restored), 100_000)
    XCTAssertTrue(restored.transactions.isEmpty)
  }

  private func execute(_ sql: String, at url: URL) throws {
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let database
    else { throw NSError(domain: "LoanRepaymentStorageTests", code: 1) }
    defer { sqlite3_close(database) }
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw NSError(domain: "LoanRepaymentStorageTests", code: 2)
    }
  }
}
