import Foundation
import XCTest

@testable import MoneyCore

final class WealthTests: XCTestCase {
  private let start = Day(rawValue: "2024-01-01")

  func testLoanRemainingPrincipalCountsOnlyPaidInstallments() throws {
    let loan = Loan(
      name: "Rodina", direction: .lent, principal: 100_000, startDay: start,
      dueDay: Day(rawValue: "2025-12-31"),
      installments: [
        LoanInstallment(
          amount: 30_000, dueDay: Day(rawValue: "2024-06-30"), paidDay: Day(rawValue: "2024-06-20")),
        LoanInstallment(amount: 20_000, dueDay: Day(rawValue: "2024-12-31")),
      ])

    XCTAssertEqual(try loan.remainingPrincipal(), 70_000)
    XCTAssertNoThrow(try Ledger.validate(loan))
  }

  func testLoanRejectsOverplannedAmountInvalidDatesAndDuplicateInstallments() throws {
    var loan = Loan(
      name: "Rodina", direction: .borrowed, principal: 100_000, startDay: start,
      installments: [
        LoanInstallment(amount: 60_000, dueDay: Day(rawValue: "2024-06-30")),
        LoanInstallment(amount: 50_000, dueDay: Day(rawValue: "2024-12-31")),
      ])
    XCTAssertThrowsError(try Ledger.validate(loan))

    loan.installments = [
      LoanInstallment(amount: 10_000, dueDay: start, paidDay: Day.today),
      LoanInstallment(amount: 10_000, dueDay: Day(rawValue: "2023-12-31")),
    ]
    XCTAssertThrowsError(try Ledger.validate(loan))

    let duplicate = UUID()
    loan.installments = [
      LoanInstallment(id: duplicate, amount: 10_000, dueDay: start),
      LoanInstallment(id: duplicate, amount: 10_000, dueDay: start),
    ]
    XCTAssertThrowsError(try Ledger.validate(loan))
  }

  func testInvestmentPerformanceUsesFlowsThroughValuationDate() throws {
    let portfolio = InvestmentPortfolio(
      name: "Fond",
      entries: [
        InvestmentEntry(kind: .deposit, amount: 100_000, day: Day(rawValue: "2024-01-01")),
        InvestmentEntry(kind: .withdrawal, amount: 10_000, day: Day(rawValue: "2024-06-01")),
        InvestmentEntry(kind: .deposit, amount: 50_000, day: Day(rawValue: "2025-01-01")),
      ], currentValue: 120_000, valuedOn: Day(rawValue: "2024-12-31"))

    XCTAssertEqual(try portfolio.performance(), 30_000)
    XCTAssertNoThrow(try Ledger.validate(portfolio))
  }

  func testInvestmentRejectsNegativeValueAndInvalidEntry() {
    let portfolio = InvestmentPortfolio(
      name: "Fond",
      entries: [
        InvestmentEntry(kind: .deposit, amount: 0, day: start)
      ], currentValue: 1, valuedOn: start)
    XCTAssertThrowsError(try Ledger.validate(portfolio))
  }

  func testSalaryFlagIsAllowedOnlyForIncome() {
    var snapshot = Snapshot()
    let account = Account(name: "Účet", openingBalance: 0, openingDay: start)
    let category = Category(name: "Mzda")
    snapshot.accounts = [account]
    snapshot.categories = [category]
    snapshot.transactions = [
      Transaction(
        kind: .expense, amount: 1, day: start, accountID: account.id, categoryID: category.id,
        isSalary: true)
    ]
    XCTAssertThrowsError(try Ledger.validate(snapshot))
  }
}
