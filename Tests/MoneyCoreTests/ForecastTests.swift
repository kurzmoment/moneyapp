import XCTest

@testable import MoneyCore

final class ForecastTests: XCTestCase {
  private let accountID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let cardID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
  private let categoryID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

  private func state() -> Snapshot {
    var state = Snapshot()
    state.accounts = [
      Account(
        id: accountID, name: "Banka", openingBalance: 100_000,
        openingDay: Day(rawValue: "2024-01-01")),
      Account(
        id: cardID, name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
        kind: .creditCard, creditLimit: 200_000),
    ]
    state.categories = [Category(id: categoryID, name: "Běžné")]
    return state
  }

  func testComparisonUsesElapsedDayAndClampsPreviousShortMonth() throws {
    var state = state()
    state.transactions = [
      Transaction(
        kind: .expense, amount: 10_000, day: Day(rawValue: "2024-02-29"), accountID: accountID,
        categoryID: categoryID),
      Transaction(
        kind: .expense, amount: 20_000, day: Day(rawValue: "2024-03-15"), accountID: accountID,
        categoryID: categoryID),
    ]
    let report = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertEqual(report.comparison?.currentExpense, 20_000)
    XCTAssertEqual(report.comparison?.previousExpense, 0)
    XCTAssertEqual(report.comparison?.previousEnd, Day(rawValue: "2024-02-15"))
    XCTAssertEqual(report.comparison?.change, 20_000)
  }

  func testForecastCountsOverdueAndFutureOccurrencesOnceAndSeparatesCredit() throws {
    var state = state()
    let cash = RecurringPayment(
      name: "Nájem", amount: 10_000, accountID: accountID, categoryID: categoryID,
      startDay: Day(rawValue: "2024-01-01"), interval: .monthly)
    let card = RecurringPayment(
      name: "Licence", amount: 5_000, accountID: cardID, categoryID: categoryID,
      startDay: Day(rawValue: "2024-02-01"), interval: .monthly)
    state.recurringPayments = [cash, card]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 10_000, day: Day(rawValue: "2024-01-01"), accountID: accountID,
        categoryID: categoryID, recurringID: cash.id, occurrenceDay: Day(rawValue: "2024-01-01"))
    ]
    let report = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    let forecast = try XCTUnwrap(report.monthEndForecast)
    XCTAssertEqual(forecast.pendingCashPayments, 20_000)
    XCTAssertEqual(forecast.pendingCreditPayments, 10_000)
    XCTAssertEqual(forecast.payments.count, 4)
  }

  func testArchivedAccountIsExcludedFromForecast() throws {
    var state = state()
    state.accounts[0].isArchived = true
    state.recurringPayments = [
      RecurringPayment(
        name: "Archivováno", amount: 1_000, accountID: accountID, categoryID: categoryID,
        startDay: Day(rawValue: "2024-03-01"), interval: .monthly)
    ]
    let report = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertEqual(report.monthEndForecast?.payments.count, 0)
  }

  func testBudgetRemainingNeverGoesNegativeAndOverflowFails() throws {
    var state = state()
    state.budgets = [Budget(categoryID: categoryID, month: "2024-03", limit: 1_000)]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 2_000, day: Day(rawValue: "2024-03-01"), accountID: accountID,
        categoryID: categoryID)
    ]
    XCTAssertEqual(
      try MonthlyReport.make(state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
        .budgets.first?.remaining, 0)
    state.transactions[0].amount = Int64.max
    state.transactions.append(
      Transaction(
        kind: .expense, amount: 1, day: Day(rawValue: "2024-03-02"), accountID: accountID,
        categoryID: categoryID))
    XCTAssertThrowsError(
      try MonthlyReport.make(state: state, month: "2024-03", today: Day(rawValue: "2024-03-15")))
  }
  func testCompleteMonthUsesWholePreviousMonthAndCurrentMonthClamps() throws {
    let state = state()
    let completed = try MonthlyReport.make(
      state: state, month: "2024-02", today: Day(rawValue: "2024-04-15"))
    XCTAssertEqual(completed.comparison?.previousEnd, Day(rawValue: "2024-01-31"))
    let current = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-31"))
    XCTAssertEqual(current.comparison?.previousEnd, Day(rawValue: "2024-02-29"))
  }

  func testForecastPreservesMonthEndAnchor() throws {
    var state = state()
    state.recurringPayments = [
      RecurringPayment(
        name: "Konec měsíce", amount: 100, accountID: accountID, categoryID: categoryID,
        startDay: Day(rawValue: "2024-01-31"), interval: .monthly)
    ]
    let report = try MonthlyReport.make(
      state: state, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertEqual(
      report.monthEndForecast?.payments.map(\.day.rawValue),
      ["2024-01-31", "2024-02-29", "2024-03-31"])
    XCTAssertEqual(report.monthEndForecast?.estimatedCashBalance, 99700)
  }

}
