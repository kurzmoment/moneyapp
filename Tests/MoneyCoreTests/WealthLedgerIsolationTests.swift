import XCTest

@testable import MoneyCore

final class WealthLedgerIsolationTests: XCTestCase {
  func testManualWealthRecordsDoNotChangeSpendingOrAccountBalances() throws {
    var state = Snapshot.empty
    let day = Day(rawValue: "2024-02-15")
    let account = Account(name: "Banka", openingBalance: 100_000, openingDay: day)
    state.accounts = [account]
    state.transactions = [
      Transaction(
        kind: .income, amount: 200_000, day: day, accountID: account.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .expense, amount: 10_000, day: day, accountID: account.id,
        categoryID: state.categories[0].id),
    ]
    let before = try SalaryPeriodReport.make(state: state, today: day)
    let balance = try Ledger.balance(account: account, in: state, through: day)
    state.loans = [
      Loan(
        name: "Dluh", direction: .borrowed, principal: 30_000,
        startDay: day,
        installments: [
          LoanInstallment(amount: 5_000, dueDay: day, paidDay: day)
        ])
    ]
    state.investments = [
      InvestmentPortfolio(
        name: "Platforma",
        entries: [
          InvestmentEntry(kind: .deposit, amount: 20_000, day: day)
        ], currentValue: 22_000, valuedOn: day)
    ]
    try Ledger.validate(state)
    let after = try SalaryPeriodReport.make(state: state, today: day)
    XCTAssertEqual(after.income, before.income)
    XCTAssertEqual(after.expense, before.expense)
    XCTAssertEqual(try Ledger.balance(account: account, in: state, through: day), balance)
  }
  func testLoanSummaryDoesNotTurnOverflowIntoZero() throws {
    let day = Day(rawValue: "2024-01-01")
    let loans = [
      Loan(name: "A", direction: .borrowed, principal: Int64.max, startDay: day),
      Loan(name: "B", direction: .borrowed, principal: 1, startDay: day),
    ]
    XCTAssertThrowsError(try LoanTotals.make(loans: loans))
  }

  func testValuationSummaryFlagsNewerMovementsAndMissingCostBasis() throws {
    let portfolio = InvestmentPortfolio(
      name: "Platforma",
      entries: [
        InvestmentEntry(kind: .deposit, amount: 20_000, day: Day(rawValue: "2024-02-02"))
      ], currentValue: 10_000, valuedOn: Day(rawValue: "2024-02-01"))
    let summary = try InvestmentSummary.make(portfolio: portfolio)
    XCTAssertTrue(summary.hasLaterMovements)
    XCTAssertFalse(summary.hasRecordedDeposits)
    XCTAssertEqual(summary.deposits, 0)
  }

}
