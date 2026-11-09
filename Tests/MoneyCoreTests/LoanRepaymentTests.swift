import XCTest

@testable import MoneyCore

final class LoanRepaymentTests: XCTestCase {
  private let accountID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
  private let categoryID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!

  private func state(
    direction: LoanDirection = .borrowed, principal: Int64 = 100_00,
    installments: [LoanInstallment] = [], active: Bool = true
  ) -> (Snapshot, Loan, RecurringPayment) {
    let start = Day(rawValue: "2024-01-01")
    let loan = Loan(
      name: "Test loan", direction: direction, principal: principal, startDay: start,
      installments: installments)
    let payment = RecurringPayment(
      name: "Loan repayment", amount: 80_00, accountID: accountID, categoryID: categoryID,
      startDay: Day(rawValue: "2024-01-31"), interval: .monthly, isActive: active, loanID: loan.id)
    var snapshot = Snapshot()
    snapshot.accounts = [
      Account(
        id: accountID, name: "Main", openingBalance: 100_000,
        openingDay: Day(rawValue: "2024-01-01"))
    ]
    snapshot.categories = [Category(id: categoryID, name: "Loans")]
    snapshot.loans = [loan]
    snapshot.recurringPayments = [payment]
    return (snapshot, loan, payment)
  }

  func testManualReceiptCreditsAccountAndReducesDebtExactlyOnce() throws {
    let installment = LoanInstallment(amount: 50_00, dueDay: Day(rawValue: "2024-02-01"))
    var (snapshot, _, _) = state(direction: .lent, installments: [installment], active: false)
    let loanID = snapshot.loans[0].id
    let receiptID = UUID()
    try Ledger.receiveLoanRepayment(
      loanID: loanID, installmentID: installment.id, receiptID: receiptID,
      accountID: accountID, amount: 30_25, paidOn: Day(rawValue: "2024-02-01"), in: &snapshot)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 103_025)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: snapshot.loans[0], in: snapshot), 69_75)
    XCTAssertTrue(snapshot.loans[0].installments.isEmpty)
    XCTAssertEqual(snapshot.transactions[0].kind, .income)
    XCTAssertNil(snapshot.transactions[0].isSalary)
    let saved = snapshot
    XCTAssertThrowsError(
      try Ledger.receiveLoanRepayment(
        loanID: loanID, installmentID: installment.id, receiptID: UUID(),
        accountID: accountID, amount: 30_25, paidOn: Day(rawValue: "2024-02-01"), in: &snapshot))
    XCTAssertThrowsError(
      try Ledger.receiveLoanRepayment(
        loanID: loanID, receiptID: receiptID,
        accountID: accountID, amount: 30_25, paidOn: Day(rawValue: "2024-02-01"), in: &snapshot))
    XCTAssertEqual(snapshot, saved)
    snapshot.transactions.removeAll()
    XCTAssertEqual(try Ledger.remainingPrincipal(for: snapshot.loans[0], in: snapshot), 100_00)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 100_000)
  }

  func testInvalidManualReceiptsAreAtomicAndOldPaidRecordsStayUnbooked() throws {
    let paid = LoanInstallment(
      amount: 20_00, dueDay: Day(rawValue: "2024-02-01"), paidDay: Day(rawValue: "2024-02-01"))
    var (snapshot, loan, _) = state(direction: .lent, installments: [paid])
    let original = snapshot
    for amount: Int64 in [0, -1, 80_01] {
      XCTAssertThrowsError(
        try Ledger.receiveLoanRepayment(
          loanID: loan.id, receiptID: UUID(), accountID: accountID, amount: amount,
          paidOn: Day(rawValue: "2024-02-01"), in: &snapshot))
      XCTAssertEqual(snapshot, original)
    }
    XCTAssertThrowsError(
      try Ledger.receiveLoanRepayment(
        loanID: loan.id, installmentID: paid.id, receiptID: UUID(), accountID: accountID,
        amount: 20_00, paidOn: Day(rawValue: "2024-02-01"), in: &snapshot))
    XCTAssertEqual(snapshot, original)
    try Ledger.receiveLoanRepayment(
      loanID: loan.id, receiptID: UUID(), accountID: accountID, amount: 80_00,
      paidOn: Day(rawValue: "2024-02-01"), in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: snapshot.loans[0], in: snapshot), 0)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 108_000)
  }

  func testMonthlyTotalIncludesSubscriptionsAndOnlyActiveOutgoingLoanPayments() throws {
    var (snapshot, _, payment) = state()
    let annual = RecurringPayment(
      name: "Roční předplatné", amount: 120_06, accountID: accountID, categoryID: categoryID,
      startDay: payment.startDay, interval: .yearly)
    let monthly = RecurringPayment(
      name: "Měsíční předplatné", amount: 20_00, accountID: accountID, categoryID: categoryID,
      startDay: payment.startDay, interval: .monthly)
    var paused = monthly
    paused.id = UUID()
    paused.isActive = false
    paused.amount = 999_00
    let lent = Loan(
      name: "Dluží mi", direction: .lent, principal: 500_00, startDay: payment.startDay)
    let incoming = RecurringPayment(
      name: "Příchozí splátka", amount: 50_00, accountID: accountID, categoryID: categoryID,
      startDay: payment.startDay, interval: .monthly, loanID: lent.id)
    snapshot.loans.append(lent)
    snapshot.recurringPayments += [annual, monthly, paused, incoming]
    try Ledger.validate(snapshot)
    let report = try MonthlyReport.make(state: snapshot, month: "2024-01")
    // 80 loan + 20 monthly + 120.06 / 12 rounded to the nearest haler.
    XCTAssertEqual(report.monthlyRecurringEstimate, 110_01)
    XCTAssertEqual(report.annualRecurring, 360_06)
    XCTAssertEqual(report.expense, 0)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 100_000)

    snapshot.recurringPayments[0].isActive = false
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), 30_01)
    snapshot.recurringPayments.removeAll()
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), 0)
  }

  func testMonthlyTotalCapsFinalInstallmentAndExcludesSettledLoan() throws {
    var (snapshot, _, payment) = state(principal: 100_00)
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), 80_00)
    try Ledger.confirm(
      payment: payment, occurrence: payment.startDay, paidOn: payment.startDay,
      amount: 80_00, in: &snapshot)
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), 20_00)
    let next = try XCTUnwrap(Ledger.nextOccurrence(for: payment, in: snapshot))
    try Ledger.confirm(
      payment: payment, occurrence: next, paidOn: next, amount: 20_00, in: &snapshot)
    XCTAssertEqual(try Ledger.monthlyRecurringCost(in: snapshot), 0)
  }

  func testMonthlyEndAndFinalCappedRepaymentSettleLoan() throws {
    var (snapshot, loan, payment) = state(principal: 100_00)
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: payment, in: snapshot), Day(rawValue: "2024-01-31"))
    XCTAssertEqual(try Ledger.recurringAmount(for: payment, in: snapshot), 80_00)

    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-01-31"),
      paidOn: Day(rawValue: "2024-01-31"), amount: 80_00, in: &snapshot)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 92_000)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 20_00)
    XCTAssertEqual(try Ledger.recurringAmount(for: payment, in: snapshot), 20_00)
    XCTAssertEqual(
      try Ledger.nextOccurrence(for: payment, in: snapshot), Day(rawValue: "2024-02-29"))

    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-02-29"),
      paidOn: Day(rawValue: "2024-02-29"), amount: 20_00, in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 0)
    XCTAssertNil(try Ledger.nextOccurrence(for: payment, in: snapshot))
  }

  func testLentRepaymentIsIncomeAndNeverSalary() throws {
    var (snapshot, _, payment) = state(direction: .lent)
    XCTAssertEqual(try Ledger.recurringKind(for: payment, in: snapshot), .income)
    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-01-31"),
      paidOn: Day(rawValue: "2024-01-31"), amount: 10_00, in: &snapshot)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[0], in: snapshot), 101_000)
    XCTAssertEqual(snapshot.transactions.single?.kind, .income)
    XCTAssertNil(snapshot.transactions.single?.isSalary)
    XCTAssertEqual(snapshot.transactions.single?.loanID, payment.loanID)
    XCTAssertEqual(snapshot.transactions.single?.recurringID, payment.id)
    XCTAssertEqual(snapshot.transactions.single?.occurrenceDay, Day(rawValue: "2024-01-31"))
  }

  func testManualPaidInstallmentIsIncludedAndUnpaidBlocksActivePlan() throws {
    let paid = LoanInstallment(
      amount: 30_00, dueDay: Day(rawValue: "2024-01-10"), paidDay: Day(rawValue: "2024-01-10"))
    var (snapshot, loan, payment) = state(principal: 100_00, installments: [paid])
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 70_00)
    XCTAssertEqual(try Ledger.recurringAmount(for: payment, in: snapshot), 70_00)

    let unpaid = LoanInstallment(amount: 10_00, dueDay: Day(rawValue: "2024-02-10"))
    snapshot.loans[0].installments.append(unpaid)
    XCTAssertThrowsError(try Ledger.validate(snapshot))
    snapshot.recurringPayments[0].isActive = false
    XCTAssertNoThrow(try Ledger.validate(snapshot))
  }

  func testBadPaidDateAndOverpayLeaveStateUnchanged() throws {
    var (snapshot, _, payment) = state()
    let original = snapshot
    XCTAssertThrowsError(
      try Ledger.confirm(
        payment: payment, occurrence: Day(rawValue: "2024-01-31"),
        paidOn: Day(rawValue: "2023-12-31"), amount: 1_00, in: &snapshot))
    XCTAssertEqual(snapshot, original)

    XCTAssertThrowsError(
      try Ledger.confirm(
        payment: payment, occurrence: Day(rawValue: "2024-01-31"),
        paidOn: Day(rawValue: "2024-01-31"), amount: 101_00, in: &snapshot))
    XCTAssertEqual(snapshot, original)
  }

  func testDuplicateConfirmationAndUndoRestoreDebt() throws {
    var (snapshot, loan, payment) = state()
    try Ledger.confirm(
      payment: payment, occurrence: Day(rawValue: "2024-01-31"),
      paidOn: Day(rawValue: "2024-01-31"), amount: 10_00, in: &snapshot)
    let afterCreation = snapshot
    XCTAssertThrowsError(
      try Ledger.confirm(
        payment: payment, occurrence: Day(rawValue: "2024-01-31"),
        paidOn: Day(rawValue: "2024-01-31"), amount: 10_00, in: &snapshot))
    XCTAssertEqual(snapshot, afterCreation)
    let beforeEdit = snapshot
    snapshot.transactions[0].amount = 20_00
    TransactionHistory.recordChanges(from: beforeEdit, in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 80_00)
    let edit = try XCTUnwrap(snapshot.transactionHistory.last)
    try TransactionHistory.undo(edit.id, in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 90_00)

    let beforeDelete = snapshot
    snapshot.transactions.removeAll()
    TransactionHistory.recordChanges(from: beforeDelete, in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 100_00)
    let deletion = try XCTUnwrap(snapshot.transactionHistory.last)
    try TransactionHistory.undo(deletion.id, in: &snapshot)
    XCTAssertEqual(try Ledger.remainingPrincipal(for: loan, in: snapshot), 90_00)
  }
}

extension Array where Element == Transaction {
  fileprivate var single: Element? { count == 1 ? first : nil }
}
