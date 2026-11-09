import XCTest

@testable import MoneyCore

final class RecurringSkipTests: XCTestCase {
  private let accountID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let categoryID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
  private let paymentID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!

  private func state(startDay: Day = Day(rawValue: "2024-01-31")) -> (Snapshot, RecurringPayment) {
    var snapshot = Snapshot()
    snapshot.accounts = [
      Account(
        id: accountID, name: "Běžný účet", openingBalance: 100_000,
        openingDay: Day(rawValue: "2024-01-01"))
    ]
    snapshot.categories = [Category(id: categoryID, name: "Bydlení")]
    let payment = RecurringPayment(
      id: paymentID, name: "Nájem", amount: 10_000, accountID: accountID,
      categoryID: categoryID, startDay: startDay, interval: .monthly)
    snapshot.recurringPayments = [payment]
    return (snapshot, payment)
  }

  func testSkippedMonthEndOccurrenceAdvancesWithoutChangingBalancesOrMonthlySummary() throws {
    var (snapshot, payment) = state()
    let beforeBalance = try Ledger.balance(account: snapshot.accounts[0], in: snapshot)
    let beforeMonthlyCost = try Ledger.monthlyRecurringCost(in: snapshot)

    try Ledger.skipMonthlyPayment(
      paymentID: payment.id, occurrence: Day(rawValue: "2024-01-31"), in: &snapshot)
    payment = try XCTUnwrap(snapshot.recurringPayments.first)

    XCTAssertEqual(payment.skippedOccurrences, [Day(rawValue: "2024-01-31")])
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: payment, in: snapshot), Day(rawValue: "2024-02-29"))
    try Ledger.skipMonthlyPayment(
      paymentID: payment.id, occurrence: Day(rawValue: "2024-02-29"), in: &snapshot)
    payment = try XCTUnwrap(snapshot.recurringPayments.first)
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: payment, in: snapshot), Day(rawValue: "2024-03-31"))
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), beforeBalance)
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), beforeMonthlyCost)
    XCTAssertTrue(snapshot.transactions.isEmpty)
  }

  func testSkipExcludesOccurrenceFromForecastAndConfirmationAndRestoreBringsItBack() throws {
    var (snapshot, payment) = state(startDay: Day(rawValue: "2024-03-01"))
    let occurrence = Day(rawValue: "2024-03-01")
    try Ledger.skipMonthlyPayment(paymentID: payment.id, occurrence: occurrence, in: &snapshot)
    payment = try XCTUnwrap(snapshot.recurringPayments.first)

    let report = try MonthlyReport.make(
      state: snapshot, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertFalse(report.monthEndForecast?.payments.contains { $0.day == occurrence } ?? false)
    XCTAssertThrowsError(
      try Ledger.confirm(
        payment: payment, occurrence: occurrence, paidOn: occurrence,
        amount: payment.amount, in: &snapshot))

    try Ledger.restoreSkippedOccurrence(
      paymentID: payment.id, occurrence: occurrence, in: &snapshot)
    payment = try XCTUnwrap(snapshot.recurringPayments.first)
    XCTAssertEqual(try Ledger.nextOccurrence(for: payment, in: snapshot), occurrence)
    let restoredReport = try MonthlyReport.make(
      state: snapshot, month: "2024-03", today: Day(rawValue: "2024-03-15"))
    XCTAssertTrue(
      restoredReport.monthEndForecast?.payments.contains { $0.day == occurrence } ?? false)
  }

  func testInvalidDuplicateAndOutOfOrderSkipOperationsAreAtomic() throws {
    var (snapshot, payment) = state(startDay: Day(rawValue: "2024-03-01"))
    let due = Day(rawValue: "2024-03-01")
    try Ledger.skipMonthlyPayment(paymentID: payment.id, occurrence: due, in: &snapshot)
    let skippedSnapshot = snapshot

    for invalidDay in [
      Day(rawValue: "2024-03-01"), Day(rawValue: "2024-02-01"),
      Day(rawValue: "2024-03-02"), Day(rawValue: "not-a-date"),
    ] {
      XCTAssertThrowsError(
        try Ledger.skipMonthlyPayment(
          paymentID: payment.id, occurrence: invalidDay, in: &snapshot))
      XCTAssertEqual(snapshot, skippedSnapshot)
    }
    XCTAssertThrowsError(
      try Ledger.restoreSkippedOccurrence(
        paymentID: payment.id, occurrence: Day(rawValue: "2024-04-01"), in: &snapshot))
    XCTAssertEqual(snapshot, skippedSnapshot)
  }

  func testValidationRejectsMalformedSkippedOccurrencesAndPaidConflict() throws {
    let (base, payment) = state()
    var malformed = base
    malformed.recurringPayments[0].skippedOccurrences = [Day(rawValue: "2024-02-30")]
    XCTAssertThrowsError(try Ledger.validate(malformed))

    malformed = base
    malformed.recurringPayments[0].skippedOccurrences = [
      Day(rawValue: "2024-01-31"), Day(rawValue: "2024-01-31"),
    ]
    XCTAssertThrowsError(try Ledger.validate(malformed))

    malformed = base
    malformed.recurringPayments[0].skippedOccurrences = [Day(rawValue: "2024-02-01")]
    XCTAssertThrowsError(try Ledger.validate(malformed))

    malformed = base
    malformed.transactions = [
      Transaction(
        kind: .expense, amount: payment.amount, day: Day(rawValue: "2024-01-31"),
        accountID: accountID, categoryID: categoryID, recurringID: payment.id,
        occurrenceDay: Day(rawValue: "2024-01-31"))
    ]
    malformed.recurringPayments[0].skippedOccurrences = [Day(rawValue: "2024-01-31")]
    XCTAssertThrowsError(try Ledger.validate(malformed))
  }

  func testSkippingBorrowedLoanOccurrenceDoesNotChangeDebtOrTransactions() throws {
    var (snapshot, payment) = state()
    let loan = Loan(
      name: "Půjčka", direction: .borrowed, principal: 50_000,
      startDay: Day(rawValue: "2024-01-01"))
    snapshot.loans = [loan]
    snapshot.recurringPayments[0].loanID = loan.id
    payment = try XCTUnwrap(snapshot.recurringPayments.first)
    try Ledger.skipMonthlyPayment(
      paymentID: payment.id, occurrence: payment.startDay, in: &snapshot)
    payment = try XCTUnwrap(snapshot.recurringPayments.first)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 50_000)
    XCTAssertTrue(snapshot.transactions.isEmpty)
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: payment, in: snapshot), Day(rawValue: "2024-02-29"))
  }

  func testIncomingPausedAndYearlyPaymentsCannotBeSkipped() throws {
    var (snapshot, payment) = state()
    let lentLoan = Loan(
      name: "Půjčka", direction: .lent, principal: 50_000,
      startDay: Day(rawValue: "2024-01-01"))
    snapshot.loans = [lentLoan]
    snapshot.recurringPayments[0].loanID = lentLoan.id
    payment = try XCTUnwrap(snapshot.recurringPayments.first)
    var original = snapshot
    XCTAssertThrowsError(
      try Ledger.skipMonthlyPayment(
        paymentID: payment.id, occurrence: payment.startDay, in: &snapshot))
    XCTAssertEqual(snapshot, original)

    snapshot.loans = []
    snapshot.recurringPayments[0].loanID = nil
    snapshot.recurringPayments[0].isActive = false
    original = snapshot
    XCTAssertThrowsError(
      try Ledger.skipMonthlyPayment(
        paymentID: payment.id, occurrence: payment.startDay, in: &snapshot))
    XCTAssertEqual(snapshot, original)

    snapshot.recurringPayments[0].isActive = true
    snapshot.recurringPayments[0].interval = .yearly
    original = snapshot
    XCTAssertThrowsError(
      try Ledger.skipMonthlyPayment(
        paymentID: payment.id, occurrence: payment.startDay, in: &snapshot))
    XCTAssertEqual(snapshot, original)
  }
}
