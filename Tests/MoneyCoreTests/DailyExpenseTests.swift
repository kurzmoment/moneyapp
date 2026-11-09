import XCTest

@testable import MoneyCore

final class DailyExpenseTests: XCTestCase {
  func testDailyExpensesSumSplitsOnceAndExcludeTransfersAndIncome() throws {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 10000, openingDay: Day(rawValue: "2024-01-01"))
    let other = Account(name: "Spoření", openingBalance: 0, openingDay: account.openingDay)
    state.accounts = [account, other]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 100, day: Day(rawValue: "2024-02-02"), accountID: account.id,
        categoryID: state.categories[0].id),
      Transaction(
        kind: .expense, amount: 300, day: Day(rawValue: "2024-02-02"), accountID: account.id,
        splits: [
          TransactionSplit(categoryID: state.categories[0].id, amount: 100),
          TransactionSplit(categoryID: state.categories[1].id, amount: 200),
        ]),
      Transaction(
        kind: .income, amount: 800, day: Day(rawValue: "2024-02-02"), accountID: account.id,
        categoryID: state.categories[0].id),
      Transaction(
        kind: .transfer, amount: 500, day: Day(rawValue: "2024-02-02"), accountID: account.id,
        destinationAccountID: other.id),
    ]
    let report = try MonthlyReport.make(
      state: state, month: "2024-02", today: Day(rawValue: "2024-03-10"))
    XCTAssertEqual(report.dailyExpenses.count, 29)
    XCTAssertEqual(report.dailyExpenses[0].amount, 0)
    XCTAssertEqual(report.dailyExpenses[1].amount, 400)
    XCTAssertEqual(try Money.sum(report.dailyExpenses.map(\.amount)), report.expense)
    let partial = try MonthlyReport.make(
      state: state, month: "2024-02", today: Day(rawValue: "2024-02-05"))
    XCTAssertEqual(partial.dailyExpenses.count, 5)
    XCTAssertTrue(
      try MonthlyReport.make(state: state, month: "2024-04", today: Day(rawValue: "2024-03-10"))
        .dailyExpenses.isEmpty)
  }
}
