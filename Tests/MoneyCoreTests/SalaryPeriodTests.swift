import XCTest

@testable import MoneyCore

final class SalaryPeriodTests: XCTestCase {
  private let today = Day(rawValue: "2024-03-15")

  func testPeriodsUseDistinctSalaryDaysAndEndBeforeNextSalary() throws {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account]
    let salaryCategory = state.categories[8].id
    state.transactions = [
      Transaction(
        kind: .income, amount: 100_000, day: Day(rawValue: "2024-01-31"), accountID: account.id,
        categoryID: salaryCategory, isSalary: true),
      Transaction(
        kind: .income, amount: 5_000, day: Day(rawValue: "2024-01-31"), accountID: account.id,
        categoryID: salaryCategory, isSalary: true),
      Transaction(
        kind: .income, amount: 100_000, day: Day(rawValue: "2024-02-29"), accountID: account.id,
        categoryID: salaryCategory, isSalary: true),
    ]

    let periods = SalaryPeriodReport.availablePeriods(in: state, today: today)
    XCTAssertEqual(
      periods,
      [
        SalaryPeriod(start: Day(rawValue: "2024-01-31"), end: Day(rawValue: "2024-02-28")),
        SalaryPeriod(start: Day(rawValue: "2024-02-29"), end: today),
      ])
    let first = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    XCTAssertEqual(first.income, 105_000)
    XCTAssertEqual(first.dailyExpenses.count, 29)
  }

  func testMissingSalaryMarkerDoesNotCreateSalaryPeriod() {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account]
    state.transactions = [
      Transaction(
        kind: .income, amount: 100_000, day: Day(rawValue: "2024-01-31"), accountID: account.id,
        categoryID: state.categories[8].id)
    ]

    XCTAssertTrue(SalaryPeriodReport.availablePeriods(in: state, today: today).isEmpty)
  }

  func testReportExcludesTransfersAndCountsSplitExpenseOnce() throws {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let savings = Account(
      name: "Spoření", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account, savings]
    let salaryDay = Day(rawValue: "2024-01-31")
    state.transactions = [
      Transaction(
        kind: .income, amount: 100_000, day: salaryDay, accountID: account.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .expense, amount: 300, day: Day(rawValue: "2024-02-01"), accountID: account.id,
        splits: [
          TransactionSplit(categoryID: state.categories[0].id, amount: 100),
          TransactionSplit(categoryID: state.categories[1].id, amount: 200),
        ]),
      Transaction(
        kind: .transfer, amount: 5_000, day: Day(rawValue: "2024-02-02"), accountID: account.id,
        destinationAccountID: savings.id),
    ]

    let report = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    XCTAssertEqual(report.income, 100_000)
    XCTAssertEqual(report.expense, 300)
    XCTAssertEqual(try Money.sum(report.categories.map(\.amount)), 300)
    XCTAssertEqual(report.dailyExpenses.first { $0.day == Day(rawValue: "2024-02-02") }?.amount, 0)
    XCTAssertEqual(
      report.dailyExpenses.first { $0.day == Day(rawValue: "2024-02-01") }?.amount, 300)
  }

  func testExpensesBeforeFirstSalaryAreOutsideSalaryPeriods() throws {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account]
    state.transactions = [
      Transaction(
        kind: .expense, amount: 900, day: Day(rawValue: "2024-01-10"), accountID: account.id,
        categoryID: state.categories[0].id),
      Transaction(
        kind: .income, amount: 100_000, day: Day(rawValue: "2024-01-31"), accountID: account.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .expense, amount: 400, day: Day(rawValue: "2024-02-05"), accountID: account.id,
        categoryID: state.categories[0].id),
    ]

    let report = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    XCTAssertEqual(report.expense, 400)
    XCTAssertEqual(report.dailyExpenses.first?.amount, 0)
  }
  func testNextSalaryDayExpenseBelongsOnlyToNewPeriod() throws {
    var state = Snapshot.empty
    let account = Account(
      name: "Banka", openingBalance: 0,
      openingDay: Day(rawValue: "2024-01-01"))
    state.accounts = [account]
    for date in ["2024-02-12", "2024-03-15"] {
      state.transactions.append(
        Transaction(
          kind: .income, amount: 100_000,
          day: Day(rawValue: date), accountID: account.id,
          categoryID: state.categories[8].id, isSalary: true))
    }
    state.transactions.append(
      Transaction(
        kind: .expense, amount: 500, day: today,
        accountID: account.id, categoryID: state.categories[0].id))
    let old = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    let current = try SalaryPeriodReport.make(state: state, today: today)
    XCTAssertEqual(old.expense, 0)
    XCTAssertEqual(current.expense, 500)
    XCTAssertEqual(current.dailyExpenses.count, 1)
    XCTAssertEqual(current.period.start, today)
  }

  func testReportSeparatesCashExpenseAndCreditRepaymentFromCreditPurchases() throws {
    var state = Snapshot.empty
    let bank = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let card = Account(
      name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
      kind: .creditCard, creditLimit: 100_000)
    state.accounts = [bank, card]
    let salaryDay = Day(rawValue: "2024-01-31")
    state.transactions = [
      Transaction(
        kind: .income, amount: 10_000, day: salaryDay, accountID: bank.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .expense, amount: 2_000, day: Day(rawValue: "2024-02-01"), accountID: bank.id,
        categoryID: state.categories[0].id),
      Transaction(
        kind: .expense, amount: 3_000, day: Day(rawValue: "2024-02-02"), accountID: card.id,
        categoryID: state.categories[0].id),
      Transaction(
        kind: .transfer, amount: 1_000, day: Day(rawValue: "2024-02-03"), accountID: bank.id,
        destinationAccountID: card.id),
    ]

    let report = try SalaryPeriodReport.make(state: state, today: today)
    XCTAssertEqual(report.expense, 5_000)
    XCTAssertEqual(report.difference, 5_000)
    XCTAssertEqual(report.cashExpense, 2_000)
    XCTAssertEqual(report.creditRepayments, 1_000)
    XCTAssertEqual(report.dailyCreditRepayments.count, report.dailyExpenses.count)
    XCTAssertEqual(
      report.dailyCreditRepayments.first { $0.day == Day(rawValue: "2024-02-03") }?.amount, 1_000)
    XCTAssertEqual(try Money.sum(report.dailyCreditRepayments.map(\.amount)), 1_000)
  }

  func testSameDaySalaryAndRepaymentAreIndependentOfInsertionOrder() throws {
    var state = Snapshot.empty
    let bank = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let card = Account(
      name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
      kind: .creditCard, creditLimit: 100_000)
    state.accounts = [bank, card]
    let day = Day(rawValue: "2024-01-31")
    let salary = Transaction(
      kind: .income, amount: 10_000, day: day, accountID: bank.id,
      categoryID: state.categories[8].id, isSalary: true)
    let repayment = Transaction(
      kind: .transfer, amount: 2_500, day: day, accountID: bank.id,
      destinationAccountID: card.id)

    state.transactions = [repayment, salary]
    let repaymentFirst = try SalaryPeriodReport.make(state: state, today: today)
    state.transactions = [salary, repayment]
    let salaryFirst = try SalaryPeriodReport.make(state: state, today: today)

    XCTAssertEqual(repaymentFirst.creditRepayments, 2_500)
    XCTAssertEqual(
      repaymentFirst.dailyCreditRepayments.count, salaryFirst.dailyCreditRepayments.count)
    XCTAssertEqual(
      repaymentFirst.dailyCreditRepayments[0].day, salaryFirst.dailyCreditRepayments[0].day)
    XCTAssertEqual(
      repaymentFirst.dailyCreditRepayments[0].amount, salaryFirst.dailyCreditRepayments[0].amount)
  }

  func testSavingsReverseAndCardToCardTransfersAreExcluded() throws {
    var state = Snapshot.empty
    let bank = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let savings = Account(
      name: "Spoření", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let card = Account(
      name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
      kind: .creditCard, creditLimit: 100_000)
    let secondCard = Account(
      name: "Druhá karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
      kind: .creditCard, creditLimit: 100_000)
    state.accounts = [bank, savings, card, secondCard]
    let salaryDay = Day(rawValue: "2024-01-31")
    state.transactions = [
      Transaction(
        kind: .income, amount: 10_000, day: salaryDay, accountID: bank.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .transfer, amount: 2_000, day: Day(rawValue: "2024-02-01"), accountID: bank.id,
        destinationAccountID: savings.id),
      Transaction(
        kind: .transfer, amount: 500, day: Day(rawValue: "2024-02-02"), accountID: card.id,
        destinationAccountID: bank.id),
      Transaction(
        kind: .transfer, amount: 700, day: Day(rawValue: "2024-02-03"), accountID: card.id,
        destinationAccountID: secondCard.id),
    ]

    let report = try SalaryPeriodReport.make(state: state, today: today)
    XCTAssertEqual(report.creditRepayments, 0)
    XCTAssertEqual(report.cashExpense, 0)
    XCTAssertTrue(report.dailyCreditRepayments.allSatisfy { $0.amount == 0 })
  }

  func testBoundariesAndTransactionChangesRecomputeTheReport() throws {
    var state = Snapshot.empty
    let bank = Account(
      name: "Banka", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"))
    let card = Account(
      name: "Karta", openingBalance: 0, openingDay: Day(rawValue: "2024-01-01"),
      kind: .creditCard, creditLimit: 100_000)
    state.accounts = [bank, card]
    let salaryDay = Day(rawValue: "2024-01-31")
    let nextSalaryDay = Day(rawValue: "2024-02-29")
    let boundaryExpense = Transaction(
      kind: .expense, amount: 900, day: nextSalaryDay, accountID: bank.id,
      categoryID: state.categories[0].id)
    let repayment = Transaction(
      kind: .transfer, amount: 1_000, day: Day(rawValue: "2024-02-10"), accountID: bank.id,
      destinationAccountID: card.id)
    state.transactions = [
      Transaction(
        kind: .income, amount: 10_000, day: salaryDay, accountID: bank.id,
        categoryID: state.categories[8].id, isSalary: true),
      Transaction(
        kind: .income, amount: 10_000, day: nextSalaryDay, accountID: bank.id,
        categoryID: state.categories[8].id, isSalary: true),
      boundaryExpense, repayment,
    ]

    let first = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    XCTAssertEqual(first.expense, 0)
    XCTAssertEqual(first.creditRepayments, 1_000)

    state.transactions.removeAll { $0.id == repayment.id }
    state.transactions.append(
      Transaction(
        kind: .expense, amount: 400, day: Day(rawValue: "2024-02-15"), accountID: bank.id,
        categoryID: state.categories[0].id))
    let changed = try SalaryPeriodReport.make(state: state, periodIndex: 0, today: today)
    XCTAssertEqual(changed.expense, 400)
    XCTAssertEqual(changed.cashExpense, 400)
    XCTAssertEqual(changed.creditRepayments, 0)
  }

}
