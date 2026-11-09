import XCTest

@testable import MoneyCore

final class SpendingDetailsTests: XCTestCase {
  private let checking = UUID()
  private let card = UUID()
  private let categoryA = UUID()
  private let categoryB = UUID()

  private func state(_ transactions: [Transaction]) -> Snapshot {
    var state = Snapshot()
    state.accounts = [
      Account(
        id: checking, name: "Běžný", openingBalance: 0, openingDay: Day(rawValue: "2026-01-01")),
      Account(
        id: card, name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2026-01-01"),
        kind: .creditCard, creditLimit: 100_000),
    ]
    state.categories = [Category(id: categoryA, name: "A"), Category(id: categoryB, name: "B")]
    state.transactions = transactions
    return state
  }

  func testInclusiveBoundsSplitsAndPaymentOrdering() throws {
    let first = Transaction(
      id: UUID(), kind: .expense,
      amount: 700, day: Day(rawValue: "2026-02-01"), accountID: checking,
      splits: [
        TransactionSplit(categoryID: categoryA, amount: 200),
        TransactionSplit(categoryID: categoryA, amount: 100),
        TransactionSplit(categoryID: categoryB, amount: 400),
      ])
    let last = Transaction(
      id: UUID(), kind: .expense,
      amount: 300, day: Day(rawValue: "2026-02-28"), accountID: checking, categoryID: categoryA)
    let outside = Transaction(
      kind: .expense, amount: 999, day: Day(rawValue: "2026-03-01"), accountID: checking,
      categoryID: categoryA)

    let details = try SpendingDetails.make(
      state: state([first, last, outside]), month: "2026-02")
    XCTAssertEqual(details.expenses.map(\.id), [first.id, last.id])
    XCTAssertEqual(details.categoryPayments[categoryA]?.map(\.amount), [300, 300])
    XCTAssertEqual(details.categoryPayments[categoryB]?.map(\.amount), [400])
  }

  func testTransfersAndCreditRepaymentsAreDisjointAndSummed() throws {
    let repayment = Transaction(
      kind: .transfer, amount: 500, day: Day(rawValue: "2026-02-10"), accountID: checking,
      destinationAccountID: card)
    let transfer = Transaction(
      kind: .transfer, amount: 200, day: Day(rawValue: "2026-02-11"), accountID: card,
      destinationAccountID: checking)
    let details = try SpendingDetails.make(
      state: state([repayment, transfer]), start: Day(rawValue: "2026-02-01"),
      end: Day(rawValue: "2026-02-28"))
    XCTAssertEqual(details.creditRepayments.map(\.id), [repayment.id])
    XCTAssertEqual(details.transfers.map(\.id), [transfer.id])
    XCTAssertEqual(details.creditRepaymentTotal, 500)
    XCTAssertEqual(details.transferTotal, 200)
  }

  func testEmptyPeriodProducesEmptyDetails() throws {
    let details = try SpendingDetails.make(
      state: state([]), start: Day(rawValue: "2026-02-01"), end: Day(rawValue: "2026-02-28"))
    XCTAssertTrue(details.expenses.isEmpty)
    XCTAssertTrue(details.categoryPayments.isEmpty)
    XCTAssertTrue(details.transfers.isEmpty)
    XCTAssertTrue(details.creditRepayments.isEmpty)
    XCTAssertEqual(details.transferTotal, 0)
    XCTAssertEqual(details.creditRepaymentTotal, 0)
  }
  func testAllCategoriesAndRankingExcludeOtherMovements() throws {
    var snapshot = state([])
    let categories = (1...9).map { Category(name: "Kategorie \($0)") }
    snapshot.categories = categories
    snapshot.transactions = categories.enumerated().map { index, category in
      Transaction(
        kind: .expense, amount: Int64(index + 1), day: Day(rawValue: "2026-02-10"),
        accountID: checking, categoryID: category.id)
    }
    snapshot.transactions.append(
      Transaction(
        kind: .income, amount: 999, day: Day(rawValue: "2026-02-10"), accountID: checking,
        categoryID: categories[0].id))
    snapshot.transactions.append(
      Transaction(
        kind: .adjustment, amount: 999, day: Day(rawValue: "2026-02-10"), accountID: checking))
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 999, day: Day(rawValue: "2026-01-31"), accountID: checking,
        categoryID: categories[0].id))
    let details = try SpendingDetails.make(state: snapshot, month: "2026-02")
    XCTAssertEqual(details.categoryPayments.count, 9)
    XCTAssertEqual(details.expenses.map(\.amount), Array((1...9).reversed()).map(Int64.init))
    XCTAssertEqual(try Money.sum(details.expenses.map(\.amount)), 45)
    let monthly = try MonthlyReport.make(state: snapshot, month: "2026-02")
    XCTAssertEqual(monthly.expense, 45)
    XCTAssertEqual(monthly.categories.count, details.categoryPayments.count)
  }

  func testLeapDayAndInvalidPeriod() throws {
    let expense = Transaction(
      kind: .expense, amount: 1, day: Day(rawValue: "2024-02-29"), accountID: checking,
      categoryID: categoryA)
    XCTAssertEqual(
      try SpendingDetails.make(state: state([expense]), month: "2024-02").expenses.count, 1)
    XCTAssertThrowsError(try SpendingDetails.make(state: state([]), month: "2026-13"))
    XCTAssertThrowsError(
      try SpendingDetails.make(
        state: state([]), start: Day(rawValue: "invalid"), end: Day(rawValue: "invalid")))
  }

  func testTransferOverflowIsReported() {
    let transfer = Transaction(
      kind: .transfer, amount: Int64.max, day: Day(rawValue: "2026-02-10"), accountID: checking,
      destinationAccountID: card)
    var second = transfer
    second.id = UUID()
    second.amount = 1
    XCTAssertThrowsError(
      try SpendingDetails.make(state: state([transfer, second]), month: "2026-02"))
  }

  func testDailyIncomeAndRepaymentsUseExactAmountsAndPeriod() throws {
    let day = Day(rawValue: "2026-02-10")
    let salary = Transaction(
      kind: .income, amount: 5_000_001, day: day, accountID: checking, categoryID: categoryA,
      isSalary: true)
    let extra = Transaction(
      kind: .income, amount: 99, day: day, accountID: checking, categoryID: categoryA)
    let repayment = Transaction(
      kind: .transfer, amount: 40_001, day: day, accountID: checking, destinationAccountID: card)
    let reverse = Transaction(
      kind: .transfer, amount: 10_000, day: day, accountID: card, destinationAccountID: checking)
    var outside = salary
    outside.id = UUID()
    outside.day = Day(rawValue: "2026-03-01")
    let snapshot = state([salary, extra, repayment, reverse, outside])
    let details = try SpendingDetails.make(state: snapshot, month: "2026-02")
    XCTAssertEqual(details.incomeByDay, [day: 5_000_100])
    XCTAssertEqual(details.repaymentsByDay, [day: 40_001])
    let salaryReport = try SalaryPeriodReport.make(state: snapshot, today: day)
    XCTAssertEqual(salaryReport.spendingDetails.incomeByDay[day], salaryReport.income)
    XCTAssertEqual(salaryReport.spendingDetails.repaymentsByDay[day], salaryReport.creditRepayments)
  }

}
