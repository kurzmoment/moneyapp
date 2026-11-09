import XCTest

@testable import MoneyCore

final class ReportTests: XCTestCase {
  func testBackdatedExpenseChangesHistoricalReportButNotAnchoredBalance() throws {
    var state = Snapshot.empty
    let category = try XCTUnwrap(state.categories.first)
    let account = Account(
      name: "Banka", openingBalance: 100_000, openingDay: Day(rawValue: "2024-02-01"))
    state.accounts = [account]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 10_000, day: Day(rawValue: "2024-01-31"), accountID: account.id,
        categoryID: category.id),
      Transaction(
        kind: .expense, amount: 20_000, day: Day(rawValue: "2024-02-01"), accountID: account.id,
        categoryID: category.id),
    ]
    try Ledger.validate(state)
    XCTAssertEqual(try Ledger.balance(account: account, in: state), 80_000)
    XCTAssertEqual(try MonthlyReport.make(state: state, month: "2024-01").expense, 10_000)
    XCTAssertEqual(try MonthlyReport.make(state: state, month: "2024-02").expense, 20_000)
  }

  func testBudgetAndRecurringPlanNeverInflateActualExpenses() throws {
    var state = Snapshot.empty
    let category = try XCTUnwrap(state.categories.first)
    let account = Account(
      name: "Banka", openingBalance: 100_000, openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account]
    state.budgets = [Budget(categoryID: category.id, month: "2024-01", limit: 20_000)]
    let payment = RecurringPayment(
      name: "Licence", amount: 10_001, accountID: account.id, categoryID: category.id,
      startDay: Day(rawValue: "2024-01-31"), interval: .yearly)
    state.recurringPayments = [payment]
    let report = try MonthlyReport.make(state: state, month: "2024-01")
    XCTAssertEqual(report.expense, 0)
    XCTAssertEqual(report.totalBalance, 100_000)
    XCTAssertEqual(report.annualRecurring, 10_001)
    XCTAssertEqual(report.monthlyRecurringEstimate, 833)
    XCTAssertEqual(report.budgets.first?.spent, 0)
    try Ledger.confirm(
      payment: payment, occurrence: payment.startDay, paidOn: Day(rawValue: "2024-02-01"),
      amount: 10_005, in: &state)
    XCTAssertEqual(try MonthlyReport.make(state: state, month: "2024-01").expense, 0)
    XCTAssertEqual(try MonthlyReport.make(state: state, month: "2024-02").expense, 10_005)
  }

  func testDayRejectsNormalizedInvalidDates() {
    for invalid in ["2024-02-30", "2023-02-29", "2024-13-01", "0000-01-01", "2024-1-01", "junk"] {
      XCTAssertFalse(Day(rawValue: invalid).isValid, invalid)
    }
    XCTAssertTrue(Day(rawValue: "2024-02-29").isValid)
  }

  func testCreditLimitIsNotWealthAndRepaymentDoesNotDoubleCountSpending() throws {
    var state = Snapshot.empty
    let category = try XCTUnwrap(state.categories.first)
    let bank = Account(name: "Banka", openingBalance: 100_000, openingDay: .today)
    let card = Account(
      name: "Kreditka", openingBalance: 0, openingDay: .today,
      kind: .creditCard, creditLimit: 500_000)
    state.accounts = [bank, card]
    state.budgets = [Budget(categoryID: category.id, month: Day.today.month, limit: 30_000)]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 20_050, day: .today,
        accountID: card.id, categoryID: category.id)
    ]
    try Ledger.validate(state)
    let before = try MonthlyReport.make(state: state, month: Day.today.month)
    XCTAssertEqual(before.totalBalance, 79_950)
    XCTAssertEqual(before.expense, 20_050)
    XCTAssertEqual(before.budgets.first?.spent, 20_050)
    XCTAssertEqual(before.creditCards[card.id]?.available, 479_950)
    try CreditCard.repay(cardID: card.id, from: bank.id, in: &state)
    let after = try MonthlyReport.make(state: state, month: Day.today.month)
    XCTAssertEqual(after.totalBalance, before.totalBalance)
    XCTAssertEqual(after.expense, before.expense)
    XCTAssertEqual(after.income, 0)
    XCTAssertEqual(after.budgets.first?.spent, before.budgets.first?.spent)
    XCTAssertEqual(after.creditCards[card.id]?.debt, 0)
    XCTAssertEqual(after.creditCards[card.id]?.available, 500_000)
    XCTAssertEqual(after.balances[bank.id], 79_950)
  }
}
