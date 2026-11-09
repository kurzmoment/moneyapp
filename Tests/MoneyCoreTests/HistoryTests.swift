import XCTest

@testable import MoneyCore

final class HistoryTests: XCTestCase {
  private func fixture() -> Snapshot {
    var state = Snapshot.empty
    state.accounts = [
      Account(name: "Účet", openingBalance: 10_000, openingDay: Day(rawValue: "2024-01-01"))
    ]
    return state
  }

  func testSplitCountsOnceAndUndoRestoresAllAllocations() throws {
    var state = fixture()
    let account = state.accounts[0]
    let categories = state.categories
    let tx = Transaction(
      kind: .expense, amount: 1000, day: Day(rawValue: "2024-02-01"), accountID: account.id,
      splits: [
        TransactionSplit(categoryID: categories[0].id, amount: 600),
        TransactionSplit(categoryID: categories[1].id, amount: 400),
      ])
    var next = state
    next.transactions.append(tx)
    TransactionHistory.recordChanges(from: state, in: &next)
    state = next
    try Ledger.validate(state)
    XCTAssertEqual(try Ledger.balance(account: account, in: state), 9000)
    let report = try MonthlyReport.make(
      state: state, month: "2024-02", today: Day(rawValue: "2024-02-15"))
    XCTAssertEqual(report.expense, 1000)
    XCTAssertEqual(report.categories.map(\.amount).sorted(), [400, 600])
    XCTAssertEqual(report.comparison?.categories.map(\.current).sorted(), [400, 600])
    next = state
    next.transactions.removeAll()
    TransactionHistory.recordChanges(from: state, in: &next)
    let deletion = try XCTUnwrap(next.transactionHistory.last)
    try TransactionHistory.undo(deletion.id, in: &next)
    XCTAssertEqual(next.transactions, [tx])
    XCTAssertEqual(try Ledger.balance(account: account, in: next), 9000)
    XCTAssertThrowsError(try TransactionHistory.undo(deletion.id, in: &next))
  }

  func testUndoRejectsConflictAndCanWalkEditsBack() throws {
    var state = fixture()
    let tx = Transaction(
      kind: .expense, amount: 100, day: Day(rawValue: "2024-02-01"),
      accountID: state.accounts[0].id, categoryID: state.categories[0].id)
    var next = state
    next.transactions = [tx]
    TransactionHistory.recordChanges(from: state, in: &next)
    let creation = try XCTUnwrap(next.transactionHistory.last)
    state = next
    next.transactions[0].amount = 200
    TransactionHistory.recordChanges(from: state, in: &next)
    let edit = try XCTUnwrap(next.transactionHistory.last)
    let unchanged = next
    XCTAssertThrowsError(try TransactionHistory.undo(creation.id, in: &next))
    XCTAssertEqual(next, unchanged)
    try TransactionHistory.undo(edit.id, in: &next)
    XCTAssertEqual(next.transactions[0].amount, 100)
    try TransactionHistory.undo(creation.id, in: &next)
    XCTAssertTrue(next.transactions.isEmpty)
  }

  func testTransferUndoRestoresBothBalancesWithoutExpense() throws {
    var state = fixture()
    state.accounts.append(
      Account(name: "Spoření", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01")))
    var next = state
    next.transactions.append(
      Transaction(
        kind: .transfer, amount: 2000, day: Day(rawValue: "2024-02-01"),
        accountID: state.accounts[0].id, destinationAccountID: state.accounts[1].id))
    TransactionHistory.recordChanges(from: state, in: &next)
    XCTAssertEqual(try Ledger.balance(account: state.accounts[1], in: next), 2000)
    try TransactionHistory.undo(XCTUnwrap(next.transactionHistory.last).id, in: &next)
    XCTAssertEqual(try Ledger.balance(account: state.accounts[0], in: next), 10000)
    XCTAssertEqual(try Ledger.balance(account: state.accounts[1], in: next), 0)
    XCTAssertEqual(try Ledger.total(kind: .expense, month: "2024-02", in: next), 0)
  }

  func testBackdatedChangeInvalidatesCheckEvenAfterUndo() throws {
    let state = fixture()
    let check = BalanceCheck(
      accountID: state.accounts[0].id, day: Day(rawValue: "2024-02-15"), balance: 10000,
      checkedAt: Date(timeIntervalSince1970: 1))
    XCTAssertFalse(try TransactionHistory.checkNeedsReview(check, in: state))
    var next = state
    next.transactions.append(
      Transaction(
        kind: .expense, amount: 100, day: Day(rawValue: "2024-02-01"),
        accountID: state.accounts[0].id, categoryID: state.categories[0].id))
    TransactionHistory.recordChanges(from: state, in: &next)
    XCTAssertTrue(try TransactionHistory.checkNeedsReview(check, in: next))
    try TransactionHistory.undo(XCTUnwrap(next.transactionHistory.last).id, in: &next)
    XCTAssertTrue(try TransactionHistory.checkNeedsReview(check, in: next))
  }
}
