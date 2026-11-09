import Foundation

/// A spending period anchored at a marked income day.
public struct SalaryPeriod: Identifiable, Equatable, Sendable {
  public let start: Day
  public let end: Day

  public var id: String { start.rawValue }

  public init(start: Day, end: Day) {
    self.start = start
    self.end = end
  }
}

/// A report whose boundaries follow explicitly marked salary income transactions.
///
/// Salary periods separate realized expenses from credit repayments. Budgets,
/// recurring plans, balances, comparisons, and forecasts remain calendar-based and
/// therefore are not part of this report.
public struct SalaryPeriodReport: Sendable {
  public let period: SalaryPeriod
  public let periods: [SalaryPeriod]
  public let income: Int64
  public let expense: Int64
  public let difference: Int64
  public let cashExpense: Int64
  public let creditRepayments: Int64
  public let dailyCreditRepayments: [DayExpense]
  public let spendingDetails: SpendingDetails
  public let categories: [CategoryTotal]
  public let dailyExpenses: [DayExpense]

  public var periodIndex: Int {
    periods.firstIndex(of: period) ?? 0
  }

  public static func availablePeriods(in state: Snapshot, today: Day = .today) -> [SalaryPeriod] {
    let salaryDays = Set(
      state.transactions.compactMap { transaction -> Day? in
        guard transaction.kind == .income, transaction.isSalary == true,
          transaction.day.isValid, transaction.day <= today
        else { return nil }
        return transaction.day
      }
    )
    .sorted()

    return salaryDays.enumerated().map { index, start in
      let end: Day
      if let next = salaryDays.dropFirst(index + 1).first {
        end = Day(
          Calendar(identifier: .gregorian).date(
            byAdding: .day, value: -1, to: next.date) ?? next.date)
      } else {
        end = today
      }
      return SalaryPeriod(start: start, end: end)
    }
  }

  public static func make(
    state: Snapshot, period: SalaryPeriod, today: Day = .today
  ) throws -> SalaryPeriodReport {
    let periods = availablePeriods(in: state, today: today)
    guard periods.contains(period) else {
      throw FinanceError.invalid("Výplatní období nebylo nalezeno.")
    }
    guard period.start <= period.end, period.end <= today else {
      throw FinanceError.invalid("Výplatní období není platné.")
    }

    let transactions = state.transactions.filter {
      $0.day >= period.start && $0.day <= period.end
    }
    let income = try Money.sum(
      Array(transactions.lazy.filter { $0.kind == .income }.map(\.amount)))
    let expense = try Money.sum(
      Array(transactions.lazy.filter { $0.kind == .expense }.map(\.amount)))

    let accountKinds = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.kind) })
    let cashExpense = try Money.sum(
      Array(
        transactions.lazy.filter {
          $0.kind == .expense && accountKinds[$0.accountID] == .standard
        }.map(\.amount)))
    let repayments = transactions.filter {
      SpendingDetails.isCreditRepayment($0, accountKinds: accountKinds)
    }
    let creditRepayments = try Money.sum(repayments.map(\.amount))
    var dailyRepaymentAmounts: [Day: Int64] = [:]
    for repayment in repayments {
      try add(repayment.amount, to: &dailyRepaymentAmounts, key: repayment.day)
    }

    var categoryAmounts: [UUID: Int64] = [:]
    var dailyAmounts: [Day: Int64] = [:]
    for transaction in transactions where transaction.kind == .expense {
      let categories =
        transaction.splits?.map { ($0.categoryID, $0.amount) }
        ?? (transaction.categoryID.map { [($0, transaction.amount)] } ?? [])
      for (categoryID, amount) in categories {
        try add(amount, to: &categoryAmounts, key: categoryID)
      }
      try add(transaction.amount, to: &dailyAmounts, key: transaction.day)
    }

    let categoryByID = Dictionary(uniqueKeysWithValues: state.categories.map { ($0.id, $0) })
    let categories = categoryAmounts.compactMap { categoryID, amount -> CategoryTotal? in
      guard let category = categoryByID[categoryID], amount > 0 else { return nil }
      return CategoryTotal(
        id: category.id, name: category.name, symbol: category.symbol, amount: amount)
    }.sorted { $0.amount == $1.amount ? $0.name < $1.name : $0.amount > $1.amount }

    var dailyExpenses: [DayExpense] = []
    var dailyCreditRepayments: [DayExpense] = []
    var day = period.start
    while day <= period.end {
      dailyExpenses.append(DayExpense(day: day, amount: dailyAmounts[day] ?? 0))
      dailyCreditRepayments.append(DayExpense(day: day, amount: dailyRepaymentAmounts[day] ?? 0))
      guard
        let nextDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: day.date)
      else { throw FinanceError.invalid("Výplatní období nelze projít po dnech.") }
      day = Day(nextDate)
    }

    return SalaryPeriodReport(
      period: period,
      periods: periods,
      income: income,
      expense: expense,
      difference: try Money.subtract(income, expense),
      cashExpense: cashExpense,
      creditRepayments: creditRepayments,
      dailyCreditRepayments: dailyCreditRepayments,
      spendingDetails: try SpendingDetails.make(state: state, start: period.start, end: period.end),
      categories: categories,
      dailyExpenses: dailyExpenses)
  }

  public static func make(
    state: Snapshot, periodIndex: Int = -1, today: Day = .today
  ) throws -> SalaryPeriodReport {
    let periods = availablePeriods(in: state, today: today)
    guard !periods.isEmpty else {
      throw FinanceError.invalid("Zatím není označený žádný příjem jako mzda.")
    }
    let index = periodIndex < 0 ? periods.count - 1 : periodIndex
    guard periods.indices.contains(index) else {
      throw FinanceError.invalid("Výplatní období nebylo nalezeno.")
    }
    return try make(state: state, period: periods[index], today: today)
  }

  private static func add<Key: Hashable>(
    _ amount: Int64, to values: inout [Key: Int64], key: Key
  ) throws {
    let addition = (values[key] ?? 0).addingReportingOverflow(amount)
    guard !addition.overflow else {
      throw FinanceError.invalid("Součet výdajů je příliš velký.")
    }
    values[key] = addition.partialValue
  }
}
