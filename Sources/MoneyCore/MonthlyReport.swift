import Foundation

public struct CategoryTotal: Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var symbol: String
  public var amount: Int64
}

public struct DayExpense: Identifiable, Sendable {
  public var day: Day
  public var amount: Int64
  public var id: String { day.rawValue }
}

public struct MonthTotal: Identifiable, Sendable {
  public var id: String
  public var expense: Int64
  public var income: Int64
}

public struct BudgetStatus: Identifiable, Sendable {
  public var id: UUID { budget.id }
  public var budget: Budget
  public var category: String
  public var spent: Int64
  public var remaining: Int64
}

public struct CategoryComparison: Identifiable, Sendable {
  public var id: UUID
  public var name: String
  public var current: Int64
  public var previous: Int64
  public var change: Int64
}

public struct MonthComparison: Sendable {
  public var currentExpense: Int64
  public var previousExpense: Int64
  public var change: Int64
  public var currentStart: Day
  public var currentEnd: Day
  public var previousStart: Day
  public var previousEnd: Day
  public var categories: [CategoryComparison]
}

public struct ForecastPayment: Identifiable, Sendable {
  public var id: String
  public var payment: RecurringPayment
  public var day: Day
  public var amount: Int64
}

public struct MonthEndForecast: Sendable {
  public var cashBalance: Int64
  public var pendingCashPayments: Int64
  public var pendingCreditPayments: Int64
  public var estimatedCashBalance: Int64
  public var payments: [ForecastPayment]
}

public struct FinanceInsight: Identifiable, Sendable {
  public var id: String
  public var title: String
  public var detail: String
  public var symbol: String
}

public struct UpcomingPayment: Identifiable, Sendable {
  public var payment: RecurringPayment
  public var day: Day
  public var amount: Int64
  public var kind: TransactionKind
  public var id: UUID { payment.id }
}

public struct MonthlyReport: Sendable {
  public var income: Int64 = 0
  public var expense: Int64 = 0
  public var difference: Int64 = 0
  public var totalBalance: Int64 = 0
  public var balances: [UUID: Int64] = [:]
  public var creditCards: [UUID: CreditCardStatus] = [:]
  public var categories: [CategoryTotal] = []
  public var spendingDetails: SpendingDetails?
  public var trend: [MonthTotal] = []
  public var dailyExpenses: [DayExpense] = []
  public var budgets: [BudgetStatus] = []
  public var insights: [FinanceInsight] = []
  public var upcoming: [UpcomingPayment] = []
  public var annualRecurring: Int64 = 0
  /// Nearest haléř, display-only estimate; never used for balance or expense totals.
  public var monthlyRecurringEstimate: Int64 = 0
  public var comparison: MonthComparison?
  public var monthEndForecast: MonthEndForecast?
  public static let empty = MonthlyReport()

  public static func make(state: Snapshot, month: String, today: Day = .today) throws
    -> MonthlyReport
  {
    var result = MonthlyReport()
    result.spendingDetails = try SpendingDetails.make(state: state, month: month)
    result.income = try Ledger.total(kind: .income, month: month, in: state)
    result.expense = try Ledger.total(kind: .expense, month: month, in: state)
    result.difference = try Money.subtract(result.income, result.expense)
    let calendar = Calendar(identifier: .gregorian)
    let start = Day(rawValue: month + "-01")
    let groupedDays = Dictionary(
      grouping: state.transactions.filter {
        $0.kind == .expense && $0.day.month == month && $0.day <= today
      }, by: \.day)
    if let days = calendar.range(of: .day, in: .month, for: start.date) {
      for number in days {
        let day = Day(rawValue: month + String(format: "-%02d", number))
        guard day <= today else { break }
        result.dailyExpenses.append(
          DayExpense(day: day, amount: try Money.sum((groupedDays[day] ?? []).map(\.amount))))
      }
    }

    for account in state.accounts where account.openingDay <= today {
      result.balances[account.id] = try Ledger.balance(account: account, in: state, through: today)
      if account.kind == .creditCard {
        guard let limit = account.creditLimit, let balance = result.balances[account.id] else {
          throw FinanceError.invalid("Kreditní karta nemá platný limit nebo zůstatek.")
        }
        let status = try CreditCard.status(balance: balance, limit: limit)
        result.creditCards[account.id] = status
        if status.overLimit > 0 {
          result.insights.append(
            FinanceInsight(
              id: "credit-limit-\(account.id)", title: "\(account.name): nad úvěrovým limitem",
              detail:
                "Aktuální evidovaný dluh překračuje limit o \(Money.format(status.overLimit)). Dostupná částka je nulová.",
              symbol: "creditcard.trianglebadge.exclamationmark"))
        }
      }
    }
    result.totalBalance = try Money.sum(Array(result.balances.values))
    for category in state.categories {
      let amount = try Ledger.spent(categoryID: category.id, month: month, in: state)
      if amount > 0 {
        result.categories.append(
          CategoryTotal(
            id: category.id, name: category.name, symbol: category.symbol, amount: amount))
      }
    }
    result.categories.sort { $0.amount > $1.amount }
    let date = Day(rawValue: month + "-01").date
    for offset in -5...0 {
      guard let prior = Calendar.current.date(byAdding: .month, value: offset, to: date) else {
        continue
      }
      let key = Day(prior).month
      result.trend.append(
        MonthTotal(
          id: key, expense: try Ledger.total(kind: .expense, month: key, in: state),
          income: try Ledger.total(kind: .income, month: key, in: state)))
    }
    for budget in state.budgets where budget.month == month {
      let spent = try Ledger.spent(categoryID: budget.categoryID, month: month, in: state)
      let name = state.categories.first { $0.id == budget.categoryID }?.name ?? "Kategorie"
      let remainingResult = budget.limit.subtractingReportingOverflow(spent)
      guard !remainingResult.overflow else {
        throw FinanceError.invalid("Rozpočet je příliš velký.")
      }
      let remaining = max(remainingResult.partialValue, 0)
      result.budgets.append(
        BudgetStatus(budget: budget, category: name, spent: spent, remaining: remaining))
      if spent > budget.limit {
        result.insights.append(
          FinanceInsight(
            id: budget.id.uuidString, title: "\(name): nad rozpočtem",
            detail:
              "Za \(month): \(Money.format(spent)) z limitu \(Money.format(budget.limit)). Překročení o \(Money.format(try Money.subtract(spent, budget.limit))).",
            symbol: "exclamationmark.circle"))
      }
    }
    result.budgets.sort { $0.category.localizedCompare($1.category) == .orderedAscending }
    result.annualRecurring = try Ledger.annualRecurringCost(in: state)
    result.monthlyRecurringEstimate = try Ledger.monthlyRecurringCost(in: state)
    result.upcoming = try state.recurringPayments.compactMap { payment in
      guard let day = try Ledger.nextOccurrence(for: payment, in: state) else { return nil }
      return UpcomingPayment(
        payment: payment, day: day,
        amount: try Ledger.recurringAmount(for: payment, in: state),
        kind: try Ledger.recurringKind(for: payment, in: state))
    }.sorted { $0.day < $1.day }
    if result.annualRecurring > 0 {
      result.insights.append(
        FinanceInsight(
          id: "recurring", title: "Pravidelné závazky pod kontrolou",
          detail:
            "Běžné aktivní platby bez půjček odpovídají \(Money.format(result.annualRecurring)) ročně (měsíční × 12 + roční). Jde o plán, nikoli o skutečně zaplacené výdaje.",
          symbol: "repeat"))
    }
    // Compare only completed months, never a partial month against an entire month.
    if month < today.month,
      let previousDate = Calendar.current.date(byAdding: .month, value: -1, to: date)
    {
      let previousMonth = Day(previousDate).month
      for category in result.categories {
        let prior = try Ledger.spent(categoryID: category.id, month: previousMonth, in: state)
        if prior > 0, category.amount > prior {
          result.insights.append(
            FinanceInsight(
              id: "growth-\(category.id)", title: "\(category.name): vyšší evidované výdaje",
              detail:
                "\(month): \(Money.format(category.amount)), \(previousMonth): \(Money.format(prior)). Rozdíl \(Money.format(try Money.subtract(category.amount, prior))). Srovnání vychází pouze ze zadaných transakcí.",
              symbol: "chart.line.uptrend.xyaxis"))
        }
      }
    }
    let monthStart = Day(rawValue: month + "-01")
    if monthStart.isValid,
      let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: monthStart.date)
    {
      let monthEnd = Day(nextMonth.addingTimeInterval(-86400))
      if month <= today.month {
        let currentEnd = month == today.month ? min(today, monthEnd) : monthEnd
        guard
          let previousStartDate = Calendar.current.date(
            byAdding: .month, value: -1, to: monthStart.date)
        else { throw FinanceError.invalid("Období nelze vypočítat.") }
        let previousStart = Day(previousStartDate)
        let elapsedDay = Calendar.current.component(.day, from: currentEnd.date)
        guard
          let followingPreviousMonth = Calendar.current.date(
            byAdding: .month, value: 1, to: previousStart.date)
        else { throw FinanceError.invalid("Období nelze vypočítat.") }
        let previousMonthEnd = Day(followingPreviousMonth.addingTimeInterval(-86400))
        let previousEnd =
          month < today.month
          ? previousMonthEnd
          : Day(
            rawValue: previousStart.month
              + String(
                format: "-%02d",
                min(elapsedDay, Calendar.current.component(.day, from: previousMonthEnd.date))))
        let current = try expense(in: state, start: monthStart, end: currentEnd)
        let previous = try expense(in: state, start: previousStart, end: previousEnd)
        var categories: [CategoryComparison] = []
        for category in state.categories {
          let currentAmount = try spent(
            in: state, categoryID: category.id, start: monthStart, end: currentEnd)
          let previousAmount = try spent(
            in: state, categoryID: category.id, start: previousStart, end: previousEnd)
          if currentAmount != 0 || previousAmount != 0 {
            categories.append(
              CategoryComparison(
                id: category.id, name: category.name, current: currentAmount,
                previous: previousAmount, change: try Money.subtract(currentAmount, previousAmount))
            )
          }
        }
        result.comparison = MonthComparison(
          currentExpense: current, previousExpense: previous,
          change: try Money.subtract(current, previous), currentStart: monthStart,
          currentEnd: currentEnd, previousStart: previousStart, previousEnd: previousEnd,
          categories: categories)
        if month == today.month {
          result.monthEndForecast = try forecast(
            state: state, monthEnd: monthEnd, today: today, balances: result.balances)
        }
      }
    }
    return result
  }

  private static func expense(in state: Snapshot, start: Day, end: Day) throws -> Int64 {
    try state.transactions.filter { $0.kind == .expense && $0.day >= start && $0.day <= end }
      .reduce(0) { partial, transaction in try checkedAdd(partial, transaction.amount) }
  }

  private static func spent(in state: Snapshot, categoryID: UUID, start: Day, end: Day) throws
    -> Int64
  {
    var values: [Int64] = []
    for transaction in state.transactions
    where transaction.kind == .expense && transaction.day >= start && transaction.day <= end {
      if let splits = transaction.splits {
        values.append(contentsOf: splits.filter { $0.categoryID == categoryID }.map(\.amount))
      } else if transaction.categoryID == categoryID {
        values.append(transaction.amount)
      }
    }
    return try Money.sum(values)
  }

  private static func forecast(state: Snapshot, monthEnd: Day, today: Day, balances: [UUID: Int64])
    throws -> MonthEndForecast
  {
    var payments: [ForecastPayment] = []
    var cash: Int64 = 0
    var credit: Int64 = 0
    let paid = Set(
      state.transactions.compactMap { transaction -> String? in
        guard let recurringID = transaction.recurringID, let occurrence = transaction.occurrenceDay
        else { return nil }
        return "\(recurringID.uuidString)-\(occurrence.rawValue)"
      })
    for payment in state.recurringPayments where payment.isActive {
      guard let account = state.accounts.first(where: { $0.id == payment.accountID }),
        !account.isArchived
      else { continue }
      guard try Ledger.recurringKind(for: payment, in: state) == .expense else { continue }
      var remainingDebt: Int64?
      if let loanID = payment.loanID {
        guard let loan = state.loans.first(where: { $0.id == loanID }) else {
          throw FinanceError.invalid("Pravidelná splátka odkazuje na neexistující půjčku.")
        }
        remainingDebt = try Ledger.remainingPrincipal(for: loan, in: state)
      }
      let skipped = Set(payment.skippedOccurrences ?? [])
      var occurrence = payment.startDay
      var iterations = 0
      while occurrence <= monthEnd {
        guard iterations < 100_000 else {
          throw FinanceError.invalid("Pravidelná platba má příliš mnoho výskytů.")
        }
        if !paid.contains("\(payment.id.uuidString)-\(occurrence.rawValue)"),
          !skipped.contains(occurrence)
        {
          let amount = min(payment.amount, remainingDebt ?? payment.amount)
          guard amount > 0 else { break }
          if let debt = remainingDebt { remainingDebt = try Money.subtract(debt, amount) }
          payments.append(
            ForecastPayment(
              id: "\(payment.id.uuidString)-\(occurrence.rawValue)", payment: payment,
              day: occurrence, amount: amount))
          if account.kind == .creditCard {
            credit = try checkedAdd(credit, amount)
          } else {
            cash = try checkedAdd(cash, amount)
          }
        }
        guard let next = Ledger.scheduledOccurrence(for: payment, index: iterations + 1) else {
          break
        }
        occurrence = next
        iterations += 1
      }
    }
    let cashBalance = try Money.sum(
      state.accounts.filter { $0.kind == .standard && !$0.isArchived }.compactMap {
        balances[$0.id]
      })
    return MonthEndForecast(
      cashBalance: cashBalance, pendingCashPayments: cash, pendingCreditPayments: credit,
      estimatedCashBalance: try Money.subtract(cashBalance, cash),
      payments: payments.sorted { $0.day == $1.day ? $0.id < $1.id : $0.day < $1.day })
  }

  private static func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else { throw FinanceError.invalid("Součet je příliš velký.") }
    return result.partialValue
  }
}
