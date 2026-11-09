import Foundation
import MoneyCore

/// Only called with --demo; its database is a separate, random temporary file.
enum DemoData {
  static func make() -> Snapshot {
    var state = Snapshot.empty
    let today = Day.today
    let first = Day(rawValue: today.month + "-01")
    let account = Account(
      name: "Běžný účet", openingBalance: 8_250_000, openingDay: Day(rawValue: "2020-01-01"))
    let savings = Account(
      name: "Spoření", openingBalance: 18_000_000, openingDay: Day(rawValue: "2020-01-01"))
    let credit = Account(
      name: "Kreditní karta", openingBalance: -450_000, openingDay: first,
      kind: .creditCard, creditLimit: 3_000_000)
    state.accounts = [account, savings, credit]
    guard let food = state.categories.first(where: { $0.name == "Potraviny" }),
      let rent = state.categories.first(where: { $0.name == "Bydlení" }),
      let salary = state.categories.first(where: { $0.name == "Mzda" }),
      let restaurant = state.categories.first(where: { $0.name == "Restaurace" }),
      let subscriptions = state.categories.first(where: { $0.name == "Předplatná" })
    else { return state }
    for offset in -5...0 {
      guard let month = Calendar.current.date(byAdding: .month, value: offset, to: first.date)
      else { continue }
      let day = Day(month)
      let salaryDay = Day(Calendar.current.date(byAdding: .day, value: 13, to: month) ?? month)
      state.transactions.append(
        Transaction(
          kind: .income, amount: 5_200_000, day: min(salaryDay, today), accountID: account.id,
          categoryID: salary.id,
          note: "Mzda", isSalary: true))
      state.transactions.append(
        Transaction(
          kind: .expense, amount: 1_650_000, day: day, accountID: account.id, categoryID: rent.id,
          note: "Nájem a energie"))
      state.transactions.append(
        Transaction(
          kind: .expense, amount: Int64(650_000 + (offset + 5) * 31_000), day: day,
          accountID: account.id, categoryID: food.id, note: "Nákupy potravin — ukázka"))
      state.transactions.append(
        Transaction(
          kind: .expense, amount: Int64(280_000 + (offset + 5) * 12_000), day: day,
          accountID: account.id, categoryID: restaurant.id, note: "Restaurace — ukázka"))
    }
    state.transactions.append(
      Transaction(
        kind: .expense, amount: 85_000, day: today,
        accountID: account.id, categoryID: food.id, note: "Dnešní nákup — ukázka"))
    // A varied current period exercises dashboard drill-down and pagination in demo only.
    for (index, category) in state.categories.filter({ $0.id != salary.id }).prefix(8).enumerated()
    {
      state.transactions.append(
        Transaction(
          kind: .expense, amount: Int64((index + 1) * 12_500), day: today,
          accountID: account.id, categoryID: category.id, note: "Ukázka: " + category.name))
    }
    state.transactions.append(
      Transaction(
        kind: .expense, amount: 45_000, day: today, accountID: credit.id,
        note: "Rozdělený nákup — ukázka",
        splits: [
          TransactionSplit(categoryID: food.id, amount: 30_000),
          TransactionSplit(categoryID: restaurant.id, amount: 15_000),
        ]))
    state.transactions.append(
      Transaction(
        kind: .transfer, amount: 450_000, day: today, accountID: account.id,
        destinationAccountID: credit.id, note: "Splátka kreditky — ukázka"))
    state.transactions.append(
      Transaction(
        kind: .transfer, amount: 200_000, day: today, accountID: account.id,
        destinationAccountID: savings.id, note: "Na spoření — ukázka"))
    state.budgets = [
      Budget(categoryID: food.id, month: today.month, limit: 750_000),
      Budget(categoryID: restaurant.id, month: today.month, limit: 500_000),
    ]
    state.recurringPayments = [
      RecurringPayment(
        name: "Hudba", amount: 16_900, accountID: account.id, categoryID: subscriptions.id,
        startDay: first, interval: .monthly),
      RecurringPayment(
        name: "Internet", amount: 49_900, accountID: account.id, categoryID: rent.id,
        startDay: first, interval: .monthly),
    ]
    state.loans = [
      Loan(
        name: "Půjčka na vybavení — ukázka", direction: .borrowed,
        principal: 350_000, startDay: first,
        installments: [
          LoanInstallment(amount: 200_000, dueDay: first, paidDay: first)
        ]),
      Loan(
        name: "Půjčka kamarádovi — ukázka", direction: .lent,
        principal: 300_000, startDay: first, dueDay: today),
    ]
    let repaymentCategory = Category(name: "Splátky půjček", symbol: "person.2")
    state.categories.append(repaymentCategory)
    for loan in state.loans {
      state.recurringPayments.append(
        RecurringPayment(
          name: "Splátka: " + loan.name, amount: 200_000, accountID: account.id,
          categoryID: repaymentCategory.id, startDay: today, interval: .monthly, loanID: loan.id))
    }
    state.investments = [
      InvestmentPortfolio(
        name: "XTB — ukázka",
        entries: [
          InvestmentEntry(kind: .deposit, amount: 1_000_000, day: first)
        ], currentValue: 1_100_000, valuedOn: today),
      InvestmentPortfolio(
        name: "Coinbase — ukázka",
        entries: [
          InvestmentEntry(kind: .deposit, amount: 500_000, day: first)
        ], currentValue: 450_000, valuedOn: today),
    ]
    return state
  }
}
