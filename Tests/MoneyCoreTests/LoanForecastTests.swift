import XCTest

@testable import MoneyCore

final class LoanForecastTests: XCTestCase {
  func testForecastCapsOutstandingDebtAndExcludesIncomingRepayments() throws {
    var state = Snapshot.empty
    let start = Day(rawValue: "2024-01-01")
    let account = Account(name: "Banka", openingBalance: 100_000, openingDay: start)
    let borrowed = Loan(name: "Dlužím", direction: .borrowed, principal: 2_500, startDay: start)
    let lent = Loan(name: "Dluží mi", direction: .lent, principal: 9_000, startDay: start)
    state.accounts = [account]
    state.loans = [borrowed, lent]
    let category = state.categories[0].id
    let outgoing = RecurringPayment(
      name: "Splátka", amount: 1_000,
      accountID: account.id, categoryID: category, startDay: start, interval: .monthly,
      loanID: borrowed.id)
    let incoming = RecurringPayment(
      name: "Vrácení", amount: 3_000,
      accountID: account.id, categoryID: category, startDay: start, interval: .monthly,
      loanID: lent.id)
    state.recurringPayments = [outgoing, incoming]
    try Ledger.validate(state)
    let report = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    let forecast = try XCTUnwrap(report.monthEndForecast)
    XCTAssertEqual(forecast.pendingCashPayments, 2_500)
    XCTAssertEqual(forecast.estimatedCashBalance, 97_500)
    XCTAssertEqual(forecast.payments.map(\.amount), [1_000, 1_000, 500])
    XCTAssertTrue(forecast.payments.allSatisfy { $0.payment.id == outgoing.id })
    XCTAssertEqual(report.annualRecurring, 0)
    XCTAssertEqual(report.upcoming.count, 2)

    try Ledger.confirm(
      payment: outgoing, occurrence: start, paidOn: start, amount: 2_000, in: &state)
    let changed = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertEqual(changed.monthEndForecast?.pendingCashPayments, 500)
    XCTAssertEqual(changed.upcoming.first { $0.payment.id == outgoing.id }?.amount, 500)
    XCTAssertEqual(changed.monthEndForecast?.estimatedCashBalance, 97_500)
  }
}
