import XCTest

@testable import MoneyCore

final class LedgerTests: XCTestCase {
  private let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  private let secondAccountID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
  private let recurringID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!

  private func baseState() -> Snapshot {
    var state = Snapshot()
    state.accounts = [
      Account(
        id: accountID, name: "Běžný účet", openingBalance: 100_00,
        openingDay: Day(rawValue: "2024-01-01")),
      Account(
        id: secondAccountID, name: "Spoření", openingBalance: 50_00,
        openingDay: Day(rawValue: "2024-01-01")),
    ]
    state.categories = [Category(id: categoryID, name: "Běžné")]
    return state
  }

  func testMoneyParsingIsExactAndSupportsInt64Minimum() throws {
    XCTAssertEqual(try Money.parse("1 234,56"), 123_456)
    XCTAssertEqual(try Money.parse("-92233720368547758,08"), Int64.min)
    XCTAssertEqual(Money.format(Int64.min), "-92 233 720 368 547 758,08 Kč")
    XCTAssertThrowsError(try Money.parse("0,001"))
    XCTAssertThrowsError(try Money.parse("92233720368547758,08"))
    XCTAssertThrowsError(try Money.subtract(Int64.min, 1))
  }

  func testBalanceCountsTransferOnBothSidesAndExcludesExpenseTotals() throws {
    var state = baseState()
    state.transactions = [
      Transaction(
        kind: .transfer, amount: 25_00, day: Day(rawValue: "2024-02-01"), accountID: accountID,
        destinationAccountID: secondAccountID),
      Transaction(
        kind: .expense, amount: 10_00, day: Day(rawValue: "2024-02-02"), accountID: accountID,
        categoryID: categoryID),
      Transaction(
        kind: .adjustment, amount: 5_00, day: Day(rawValue: "2024-02-03"), accountID: accountID),
    ]

    XCTAssertEqual(
      try Ledger.balance(
        account: state.accounts[0], in: state, through: Day(rawValue: "2024-02-29")), 70_00)
    XCTAssertEqual(
      try Ledger.balance(
        account: state.accounts[1], in: state, through: Day(rawValue: "2024-02-29")), 75_00)
    XCTAssertEqual(try Ledger.total(kind: .expense, month: "2024-02", in: state), 10_00)
    XCTAssertEqual(try Ledger.total(kind: .income, month: "2024-02", in: state), 0)
    XCTAssertEqual(try Ledger.spent(categoryID: categoryID, month: "2024-02", in: state), 10_00)
  }

  func testRecurringMonthEndLeapYearAndIdempotentConfirmation() throws {
    var state = baseState()
    let payment = RecurringPayment(
      id: recurringID, name: "Nájem", amount: 80_00, accountID: accountID, categoryID: categoryID,
      startDay: Day(rawValue: "2024-01-31"), interval: .monthly)
    state.recurringPayments = [payment]
    XCTAssertEqual(try Ledger.nextOccurrence(for: payment, in: state), Day(rawValue: "2024-01-31"))

    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-01-31"),
      paidOn: Day(rawValue: "2024-01-31"), amount: 80_00, in: &state)
    XCTAssertEqual(state.transactions.last?.note, payment.name)
    XCTAssertThrowsError(
      try Ledger.confirm(
        payment: payment, occurrence: Day(rawValue: "2024-01-31"),
        paidOn: Day(rawValue: "2024-01-31"), amount: 80_00, in: &state))
    XCTAssertEqual(try Ledger.nextOccurrence(for: payment, in: state), Day(rawValue: "2024-02-29"))
    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-02-29"),
      paidOn: Day(rawValue: "2024-02-29"), amount: 80_00, in: &state)
    XCTAssertEqual(try Ledger.nextOccurrence(for: payment, in: state), Day(rawValue: "2024-03-31"))

    let yearly = RecurringPayment(
      name: "Licence", amount: 10_00, accountID: accountID, categoryID: categoryID,
      startDay: Day(rawValue: "2020-02-29"), interval: .yearly)
    var yearlyState = baseState()
    yearlyState.recurringPayments = [yearly]
    for date in ["2020-02-29", "2021-02-28", "2022-02-28", "2023-02-28"] {
      try Ledger.confirm(
        payment: yearly, occurrence: Day(rawValue: date), paidOn: Day(rawValue: date),
        amount: yearly.amount, in: &yearlyState)
    }
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: yearly, in: yearlyState), Day(rawValue: "2024-02-29"))
  }

  func testMalformedRelationshipsAndDuplicateBudgetAreRejected() {
    var state = baseState()
    state.budgets = [
      Budget(categoryID: categoryID, month: "2024-01", limit: 0),
      Budget(categoryID: categoryID, month: "2024-01", limit: 20_00),
    ]
    XCTAssertThrowsError(try Ledger.validate(state))

    state.budgets.removeLast()
    XCTAssertNoThrow(try Ledger.validate(state))
    state.transactions = [
      Transaction(
        kind: .transfer, amount: 1_00, day: Day(rawValue: "2024-01-01"), accountID: accountID)
    ]
    XCTAssertThrowsError(try Ledger.validate(state))

    state.transactions = [
      Transaction(
        kind: .adjustment, amount: 1_00, day: Day(rawValue: "2024-01-01"), accountID: accountID)
    ]
    XCTAssertThrowsError(try Ledger.validate(state))
  }

  func testFutureTransactionsAreRejected() {
    var state = baseState()
    let future = Day(Date(timeIntervalSinceNow: 86_400))
    state.transactions = [
      Transaction(
        kind: .income, amount: 1_00, day: future, accountID: accountID, categoryID: categoryID)
    ]
    XCTAssertThrowsError(try Ledger.validate(state))
  }

  func testHistoricalRecurringTransactionSurvivesTemplateAccountAndCategoryEdit() throws {
    var state = baseState()
    let payment = RecurringPayment(
      id: recurringID, name: "Nájem", amount: 80_00, accountID: accountID, categoryID: categoryID,
      startDay: Day(rawValue: "2024-01-31"), interval: .monthly)
    state.recurringPayments = [payment]
    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-01-31"),
      paidOn: Day(rawValue: "2024-01-31"), amount: 80_00, in: &state)

    let changedCategoryID = UUID()
    state.categories.append(Category(id: changedCategoryID, name: "Nová kategorie"))
    state.recurringPayments[0].accountID = secondAccountID
    state.recurringPayments[0].categoryID = changedCategoryID
    XCTAssertNoThrow(try Ledger.validate(state))
  }

  func testOverflowAndHistoricalTransferRespectOpeningAnchors() throws {
    var overflow = baseState()
    overflow.accounts[0].openingBalance = Int64.max
    overflow.transactions = [
      Transaction(
        kind: .income, amount: 1, day: Day(rawValue: "2024-01-02"), accountID: accountID,
        categoryID: categoryID)
    ]
    XCTAssertThrowsError(
      try Ledger.balance(
        account: overflow.accounts[0], in: overflow, through: Day(rawValue: "2024-01-02")))

    var state = Snapshot()
    state.accounts = [
      Account(
        id: accountID, name: "Zdroj", openingBalance: 1_000, openingDay: Day(rawValue: "2024-01-01")
      ),
      Account(
        id: secondAccountID, name: "Cíl", openingBalance: 500,
        openingDay: Day(rawValue: "2024-03-01")),
    ]
    state.categories = [Category(id: categoryID, name: "Běžné")]
    state.transactions = [
      Transaction(
        kind: .transfer, amount: 100, day: Day(rawValue: "2024-02-15"), accountID: accountID,
        destinationAccountID: secondAccountID)
    ]
    XCTAssertEqual(
      try Ledger.balance(
        account: state.accounts[0], in: state, through: Day(rawValue: "2024-02-28")), 900)
    XCTAssertThrowsError(
      try Ledger.balance(
        account: state.accounts[1], in: state, through: Day(rawValue: "2024-02-28")))
    XCTAssertEqual(
      try Ledger.balance(
        account: state.accounts[1], in: state, through: Day(rawValue: "2024-03-01")), 500)
  }
}
