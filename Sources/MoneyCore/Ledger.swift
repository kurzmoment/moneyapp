import Foundation

public enum Ledger {
  private static let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
    return calendar
  }()

  public static func validate(_ state: Snapshot) throws {
    guard state.schemaVersion == 6 else { throw FinanceError.invalid("Neplatná verze zálohy.") }

    try validateUniqueIDs(state.accounts.map(\.id), label: "účtů")
    try validateUniqueIDs(state.categories.map(\.id), label: "kategorií")
    try validateUniqueIDs(state.transactions.map(\.id), label: "transakcí")
    try validateUniqueIDs(state.budgets.map(\.id), label: "rozpočtů")
    try validateUniqueIDs(state.recurringPayments.map(\.id), label: "pravidelných plateb")
    try validateUniqueIDs(state.savingsGoals.map(\.id), label: "spořicích cílů")
    try validateUniqueIDs(state.balanceChecks.map(\.id), label: "kontrol zůstatku")
    try validateUniqueIDs(state.transactionHistory.map(\.id), label: "změn transakcí")
    try validateUniqueIDs(state.loans.map(\.id), label: "půjček")
    try validateUniqueIDs(state.investments.map(\.id), label: "investičních portfolií")

    var installmentIDs: [UUID] = []
    for loan in state.loans { installmentIDs.append(contentsOf: loan.installments.map(\.id)) }
    try validateUniqueIDs(installmentIDs, label: "splátek")
    var investmentEntryIDs: [UUID] = []
    for portfolio in state.investments {
      investmentEntryIDs.append(contentsOf: portfolio.entries.map(\.id))
    }
    try validateUniqueIDs(investmentEntryIDs, label: "pohybů investic")

    let accounts = Set(state.accounts.map(\.id))
    let categories = Set(state.categories.map(\.id))
    let recurringByID = Dictionary(
      uniqueKeysWithValues: state.recurringPayments.map { ($0.id, $0) })
    let loansByID = Dictionary(uniqueKeysWithValues: state.loans.map { ($0.id, $0) })

    for goal in state.savingsGoals {
      guard !goal.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
        goal.target > 0, goal.saved >= 0
      else { throw FinanceError.invalid("Spořicí cíl má neplatný název nebo částku.") }
    }
    for check in state.balanceChecks {
      guard accounts.contains(check.accountID) else {
        throw FinanceError.invalid("Kontrola zůstatku odkazuje na neexistující účet.")
      }
      try requireValid(check.day, message: "Kontrola zůstatku obsahuje neplatné datum.")
      guard check.day <= .today, check.checkedAt.timeIntervalSince1970.isFinite else {
        throw FinanceError.invalid("Kontrola zůstatku obsahuje neplatný čas.")
      }
    }

    for account in state.accounts {
      guard !account.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw FinanceError.invalid("Účet musí mít název.")
      }
      try requireValid(account.openingDay, message: "Účet obsahuje neplatné datum.")
      guard account.openingDay <= .today else {
        throw FinanceError.invalid("Účet nemůže být otevřen v budoucnu.")
      }
      switch account.kind {
      case .standard:
        guard account.creditLimit == nil else {
          throw FinanceError.invalid("Běžný účet nemůže mít úvěrový limit.")
        }
      case .creditCard:
        guard let creditLimit = account.creditLimit, creditLimit > 0 else {
          throw FinanceError.invalid("Kreditní karta musí mít kladný úvěrový limit.")
        }
      }
    }
    for category in state.categories {
      guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw FinanceError.invalid("Kategorie musí mít název.")
      }
      guard !category.symbol.isEmpty else {
        throw FinanceError.invalid("Kategorie musí mít symbol.")
      }
    }

    var budgetPairs = Set<String>()
    for budget in state.budgets {
      guard categories.contains(budget.categoryID) else {
        throw FinanceError.invalid("Rozpočet odkazuje na neexistující kategorii.")
      }
      try requireValidMonth(budget.month)
      guard budget.limit >= 0 else {
        throw FinanceError.invalid("Limit rozpočtu nesmí být záporný.")
      }
      guard budgetPairs.insert("\(budget.categoryID.uuidString)|\(budget.month)").inserted else {
        throw FinanceError.invalid("Kategorie má pro měsíc více rozpočtů.")
      }
    }

    var loanRecurringIDs = Set<UUID>()
    for payment in state.recurringPayments {
      guard !payment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw FinanceError.invalid("Pravidelná platba musí mít název.")
      }
      guard payment.amount > 0 else {
        throw FinanceError.invalid("Částka pravidelné platby musí být kladná.")
      }
      guard accounts.contains(payment.accountID) else {
        throw FinanceError.invalid("Pravidelná platba odkazuje na neexistující účet.")
      }
      guard categories.contains(payment.categoryID) else {
        throw FinanceError.invalid("Pravidelná platba odkazuje na neexistující kategorii.")
      }
      try requireValid(payment.startDay, message: "Pravidelná platba obsahuje neplatné datum.")
      let skipped = payment.skippedOccurrences ?? []
      guard Set(skipped).count == skipped.count else {
        throw FinanceError.invalid("Výskyt platby je přeskočen vícekrát.")
      }
      for day in skipped {
        guard payment.interval == .monthly, day.isValid, day >= payment.startDay,
          day <= .today, isScheduled(day, for: payment)
        else {
          throw FinanceError.invalid("Přeskočený termín neodpovídá měsíčnímu plánu platby.")
        }
      }
      if let loanID = payment.loanID {
        guard let loan = loansByID[loanID] else {
          throw FinanceError.invalid("Plán splátky odkazuje na neexistující půjčku.")
        }
        guard payment.interval == .monthly else {
          throw FinanceError.invalid("Plán splátky půjčky musí být měsíční.")
        }
        guard skipped.isEmpty || loan.direction == .borrowed else {
          throw FinanceError.invalid("Přeskočení je možné pouze u odchozích plateb.")
        }
        guard payment.startDay >= loan.startDay else {
          throw FinanceError.invalid("Plán splátky nesmí začínat před půjčkou.")
        }
        guard let account = state.accounts.first(where: { $0.id == payment.accountID }),
          account.kind == .standard
        else {
          throw FinanceError.invalid("Plán splátky půjčky musí používat běžný účet.")
        }
        guard !payment.isActive || loan.installments.allSatisfy({ $0.paidDay != nil }) else {
          throw FinanceError.invalid(
            "Plán splátky nelze použít, dokud má půjčka neuhrazené ruční splátky.")
        }
        guard loanRecurringIDs.insert(loanID).inserted else {
          throw FinanceError.invalid("Půjčka může mít nejvýše jeden plán splátek.")
        }
      }
    }

    for loan in state.loans { try validate(loan) }
    for investment in state.investments { try validate(investment) }

    var recurringOccurrences = Set<String>()
    var monthlyTotals = [String: Int64]()
    var categoryTotals = [String: Int64]()
    var linkedLoanTotals: [UUID: Int64] = [:]
    for transaction in state.transactions {
      try requireValid(transaction.day, message: "Transakce obsahuje neplatné datum.")
      guard transaction.day <= .today else {
        throw FinanceError.invalid("Transakce nemůže být v budoucnu.")
      }
      guard accounts.contains(transaction.accountID) else {
        throw FinanceError.invalid("Transakce odkazuje na neexistující účet.")
      }
      guard transaction.isSalary != true || transaction.kind == .income else {
        throw FinanceError.invalid("Mzda může být označena pouze u příjmu.")
      }
      switch transaction.kind {
      case .expense, .income:
        guard transaction.amount > 0 else {
          throw FinanceError.invalid("Částka transakce musí být kladná.")
        }
        guard transaction.destinationAccountID == nil else {
          throw FinanceError.invalid("Příjem ani výdaj nemůže mít cílový účet.")
        }
        if transaction.splits == nil {
          guard let categoryID = transaction.categoryID, categories.contains(categoryID) else {
            throw FinanceError.invalid("Příjem nebo výdaj musí odkazovat na kategorii.")
          }
          if transaction.kind == .expense {
            try add(
              transaction.amount, to: &categoryTotals,
              key: "\(categoryID.uuidString)|\(transaction.day.month)")
          }
        } else {
          guard transaction.categoryID == nil else {
            throw FinanceError.invalid("Výdaj s rozpadem nesmí mít hlavní kategorii.")
          }
        }
        if let splits = transaction.splits {
          guard transaction.kind == .expense, splits.count >= 2 else {
            throw FinanceError.invalid(
              "Rozpad částky je povolen pouze u výdajů a musí mít alespoň dvě položky.")
          }
          try validateUniqueIDs(splits.map(\.id), label: "položek rozpadu")
          var splitTotal: Int64 = 0
          for split in splits {
            guard categories.contains(split.categoryID), split.amount > 0 else {
              throw FinanceError.invalid("Položka rozpadu má neplatnou kategorii nebo částku.")
            }
            let sum = splitTotal.addingReportingOverflow(split.amount)
            guard !sum.overflow else {
              throw FinanceError.invalid("Součet rozpadu je příliš velký.")
            }
            splitTotal = sum.partialValue
            try add(
              split.amount, to: &categoryTotals,
              key: "\(split.categoryID.uuidString)|\(transaction.day.month)")
          }
          guard splitTotal == transaction.amount else {
            throw FinanceError.invalid("Součet rozpadu neodpovídá částce výdaje.")
          }
        }
      case .transfer:
        guard transaction.splits == nil else {
          throw FinanceError.invalid("Převod nemůže mít rozpad.")
        }
        guard transaction.amount > 0 else {
          throw FinanceError.invalid("Částka převodu musí být kladná.")
        }
        guard let destination = transaction.destinationAccountID,
          accounts.contains(destination), destination != transaction.accountID
        else {
          throw FinanceError.invalid("Převod musí mít jiný existující cílový účet.")
        }
        guard transaction.categoryID == nil else {
          throw FinanceError.invalid("Převod nemůže mít kategorii.")
        }
      case .adjustment:
        guard transaction.splits == nil else {
          throw FinanceError.invalid("Dorovnání nemůže mít rozpad.")
        }
        guard transaction.amount != 0 else {
          throw FinanceError.invalid("Dorovnání nesmí být nulové.")
        }
        guard transaction.destinationAccountID == nil, transaction.categoryID == nil else {
          throw FinanceError.invalid("Dorovnání nemůže mít cílový účet ani kategorii.")
        }
        guard !transaction.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          throw FinanceError.invalid("Dorovnání musí mít důvod.")
        }
      }

      if let loanID = transaction.loanID {
        guard let loan = loansByID[loanID] else {
          throw FinanceError.invalid("Splátka odkazuje na neexistující půjčku.")
        }
        let expectedKind: TransactionKind = loan.direction == .borrowed ? .expense : .income
        guard transaction.kind == expectedKind else {
          throw FinanceError.invalid("Druh transakce neodpovídá směru půjčky.")
        }
        guard transaction.isSalary != true, transaction.splits == nil,
          transaction.destinationAccountID == nil
        else {
          throw FinanceError.invalid("Splátka půjčky nesmí být mzda, rozpad ani převod.")
        }
        guard transaction.day >= loan.startDay else {
          throw FinanceError.invalid("Datum splátky nesmí být před začátkem půjčky.")
        }
        guard let account = state.accounts.first(where: { $0.id == transaction.accountID }),
          account.kind == .standard, transaction.day >= account.openingDay
        else {
          throw FinanceError.invalid("Splátka půjčky musí být na běžném účtu po jeho otevření.")
        }
        let total = linkedLoanTotals[loanID, default: 0].addingReportingOverflow(transaction.amount)
        guard !total.overflow else {
          throw FinanceError.invalid("Součet splátek půjčky je příliš velký.")
        }
        linkedLoanTotals[loanID] = total.partialValue
      }

      if let recurringID = transaction.recurringID {
        guard let occurrence = transaction.occurrenceDay,
          let payment = recurringByID[recurringID]
        else {
          throw FinanceError.invalid("Vazba pravidelné platby v transakci je neplatná.")
        }
        if let loanID = payment.loanID {
          guard transaction.loanID == loanID,
            let loan = loansByID[loanID],
            transaction.kind == (loan.direction == .borrowed ? .expense : .income)
          else {
            throw FinanceError.invalid("Vazba splátky půjčky v transakci je neplatná.")
          }
        } else {
          guard transaction.loanID == nil, transaction.kind == .expense else {
            throw FinanceError.invalid("Vazba pravidelné platby v transakci je neplatná.")
          }
        }
        try requireValid(occurrence, message: "Výskyt pravidelné platby obsahuje neplatné datum.")
        guard !(payment.skippedOccurrences ?? []).contains(occurrence) else {
          throw FinanceError.invalid("Přeskočená platba nemůže být zároveň uhrazená.")
        }
        guard occurrence >= payment.startDay,
          isScheduled(occurrence, for: payment)
        else {
          throw FinanceError.invalid("Výskyt pravidelné platby neodpovídá jejímu plánu.")
        }
        let key = "\(recurringID.uuidString)|\(occurrence.rawValue)"
        guard recurringOccurrences.insert(key).inserted else {
          throw FinanceError.invalid("Výskyt pravidelné platby je potvrzen vícekrát.")
        }
      } else if transaction.occurrenceDay != nil {
        throw FinanceError.invalid("Datum výskytu vyžaduje vazbu na pravidelnou platbu.")
      }

      try add(
        transaction.amount, to: &monthlyTotals,
        key: "\(transaction.kind.rawValue)|\(transaction.day.month)")
    }

    for loan in state.loans {
      let manual = try Money.sum(
        loan.installments.compactMap { $0.paidDay == nil ? nil : $0.amount })
      let linked = linkedLoanTotals[loan.id, default: 0]
      let total = manual.addingReportingOverflow(linked)
      guard !total.overflow, total.partialValue <= loan.principal else {
        throw FinanceError.invalid("Součet uhrazených splátek nesmí převýšit jistinu půjčky.")
      }
    }

    for change in state.transactionHistory {
      guard change.date.timeIntervalSince1970.isFinite,
        change.before != nil || change.after != nil
      else {
        throw FinanceError.invalid("Historie změny transakce je neplatná.")
      }
      if let before = change.before, let after = change.after, before.id != after.id {
        throw FinanceError.invalid("Historie změny odkazuje na dvě různé transakce.")
      }
      if let revertedAt = change.revertedAt, !revertedAt.timeIntervalSince1970.isFinite {
        throw FinanceError.invalid("Historie obsahuje neplatný čas vrácení.")
      }
      for transaction in [change.before, change.after].compactMap({ $0 }) {
        try requireValid(transaction.day, message: "Historie obsahuje neplatné datum transakce.")
        guard transaction.amount != 0 else {
          throw FinanceError.invalid("Historie obsahuje nulovou částku.")
        }
      }
    }

    try validateAccountBalanceOverflow(state)
    for account in state.accounts where account.kind == .creditCard {
      guard let limit = account.creditLimit else {
        throw FinanceError.invalid("Kreditní karta musí mít kladný úvěrový limit.")
      }
      let balance = try balance(account: account, in: state)
      _ = try CreditCard.status(balance: balance, limit: limit)
    }
    _ = try monthlyRecurringCost(in: state)
  }

  public static func validate(_ loan: Loan) throws {
    guard !loan.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FinanceError.invalid("Půjčka musí mít název.")
    }
    guard loan.principal > 0 else {
      throw FinanceError.invalid("Jistina půjčky musí být kladná.")
    }
    try requireValid(loan.startDay, message: "Půjčka obsahuje neplatné datum začátku.")
    guard loan.startDay <= .today else {
      throw FinanceError.invalid("Půjčka nemůže začínat v budoucnu.")
    }
    if let dueDay = loan.dueDay {
      try requireValid(dueDay, message: "Půjčka obsahuje neplatné datum splatnosti.")
      guard dueDay >= loan.startDay else {
        throw FinanceError.invalid("Splatnost půjčky nesmí být před jejím začátkem.")
      }
    }
    try validateUniqueIDs(loan.installments.map(\.id), label: "splátek")
    var scheduled: Int64 = 0
    for installment in loan.installments {
      guard installment.amount > 0 else {
        throw FinanceError.invalid("Částka splátky musí být kladná.")
      }
      try requireValid(installment.dueDay, message: "Splátka obsahuje neplatné datum splatnosti.")
      guard installment.dueDay >= loan.startDay else {
        throw FinanceError.invalid("Splatnost splátky nesmí být před začátkem půjčky.")
      }
      let total = scheduled.addingReportingOverflow(installment.amount)
      guard !total.overflow else { throw FinanceError.invalid("Součet splátek je příliš velký.") }
      scheduled = total.partialValue
      if let paidDay = installment.paidDay {
        try requireValid(paidDay, message: "Splátka obsahuje neplatné datum úhrady.")
        guard paidDay >= loan.startDay, paidDay <= .today else {
          throw FinanceError.invalid("Datum úhrady splátky je neplatné.")
        }
      }
    }
    guard scheduled <= loan.principal else {
      throw FinanceError.invalid("Součet plánovaných splátek nesmí převýšit jistinu.")
    }
    let paid = try Money.sum(loan.installments.compactMap { $0.paidDay == nil ? nil : $0.amount })
    _ = try Money.subtract(loan.principal, paid)
  }

  public static func remainingPrincipal(for loan: Loan) throws -> Int64 {
    try remainingPrincipal(for: loan, transactions: [])
  }

  /// Returns the outstanding principal after both manually marked installments and
  /// confirmed repayment transactions have been applied.
  public static func remainingPrincipal(for loan: Loan, in state: Snapshot) throws -> Int64 {
    guard let stored = state.loans.first(where: { $0.id == loan.id }), stored == loan else {
      throw FinanceError.invalid("Půjčka nebyla nalezena.")
    }
    return try remainingPrincipal(for: loan, transactions: state.transactions)
  }

  static func remainingPrincipal(for loan: Loan, transactions: [Transaction]) throws -> Int64 {
    try validate(loan)
    let manual = try Money.sum(loan.installments.compactMap { $0.paidDay == nil ? nil : $0.amount })
    let linked = try Money.sum(transactions.filter { $0.loanID == loan.id }.map(\.amount))
    let paid = try Money.sum([manual, linked])
    guard paid <= loan.principal else {
      throw FinanceError.invalid("Součet uhrazených splátek nesmí převýšit jistinu půjčky.")
    }
    return try Money.subtract(loan.principal, paid)
  }

  public static func validate(_ portfolio: InvestmentPortfolio) throws {
    guard !portfolio.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw FinanceError.invalid("Investiční portfolio musí mít název.")
    }
    guard portfolio.currentValue >= 0 else {
      throw FinanceError.invalid("Aktuální hodnota investice nesmí být záporná.")
    }
    try requireValid(portfolio.valuedOn, message: "Investice obsahuje neplatné datum ocenění.")
    guard portfolio.valuedOn <= .today else {
      throw FinanceError.invalid("Datum ocenění investice nemůže být v budoucnu.")
    }
    try validateUniqueIDs(portfolio.entries.map(\.id), label: "pohybů investic")
    for entry in portfolio.entries {
      guard entry.amount > 0 else {
        throw FinanceError.invalid("Částka pohybu investice musí být kladná.")
      }
      try requireValid(entry.day, message: "Pohyb investice obsahuje neplatné datum.")
      guard entry.day <= .today else {
        throw FinanceError.invalid("Pohyb investice nemůže být v budoucnu.")
      }
    }
    _ = try performanceValue(of: portfolio)
  }

  public static func performance(of portfolio: InvestmentPortfolio) throws -> Int64 {
    try validate(portfolio)
    return try performanceValue(of: portfolio)
  }

  private static func performanceValue(of portfolio: InvestmentPortfolio) throws -> Int64 {
    // A valuation is a snapshot. Movements after its date belong to a later
    // valuation and must not change this result.
    let relevant = portfolio.entries.filter { $0.day <= portfolio.valuedOn }
    let deposits = try Money.sum(
      relevant.filter { $0.kind == .deposit }.map(\.amount))
    let withdrawals = try Money.sum(
      relevant.filter { $0.kind == .withdrawal }.map(\.amount))
    let valueAndWithdrawals = try Money.sum([portfolio.currentValue, withdrawals])
    return try Money.subtract(valueAndWithdrawals, deposits)
  }

  public static func balance(account: Account, in state: Snapshot, through: Day = .today) throws
    -> Int64
  {
    try requireValid(through, message: "Datum zůstatku je neplatné.")
    guard let stored = state.accounts.first(where: { $0.id == account.id }) else {
      throw FinanceError.invalid("Účet nebyl nalezen.")
    }
    try requireValid(stored.openingDay, message: "Účet obsahuje neplatné datum.")
    guard through >= stored.openingDay else {
      throw FinanceError.invalid("Datum je před otevřením účtu.")
    }

    var result = stored.openingBalance
    let relevant = state.transactions
      .filter { $0.day >= stored.openingDay && $0.day <= through }
      .sorted { $0.day == $1.day ? $0.id.uuidString < $1.id.uuidString : $0.day < $1.day }
    for transaction in relevant {
      let delta: Int64?
      switch transaction.kind {
      case .expense:
        delta = transaction.accountID == stored.id ? try checkedNegation(transaction.amount) : nil
      case .income: delta = transaction.accountID == stored.id ? transaction.amount : nil
      case .adjustment: delta = transaction.accountID == stored.id ? transaction.amount : nil
      case .transfer:
        if transaction.accountID == stored.id {
          delta = try checkedNegation(transaction.amount)
        } else if transaction.destinationAccountID == stored.id {
          delta = transaction.amount
        } else {
          delta = nil
        }
      }
      if let delta {
        let addition = result.addingReportingOverflow(delta)
        guard !addition.overflow else {
          throw FinanceError.invalid("Zůstatek účtu je příliš velký.")
        }
        result = addition.partialValue
      }
    }
    return result
  }

  public static func total(kind: TransactionKind, month: String, in state: Snapshot) throws -> Int64
  {
    try requireValidMonth(month)
    var result: Int64 = 0
    for transaction in state.transactions
    where transaction.kind == kind && transaction.day.month == month {
      let addition = result.addingReportingOverflow(transaction.amount)
      guard !addition.overflow else {
        throw FinanceError.invalid("Součet transakcí je příliš velký.")
      }
      result = addition.partialValue
    }
    return result
  }

  public static func spent(categoryID: UUID, month: String, in state: Snapshot) throws -> Int64 {
    try requireValidMonth(month)
    guard state.categories.contains(where: { $0.id == categoryID }) else {
      throw FinanceError.invalid("Kategorie nebyla nalezena.")
    }
    var result: Int64 = 0
    for transaction in state.transactions
    where transaction.kind == .expense && transaction.day.month == month {
      let amount: Int64
      if let splits = transaction.splits {
        var splitTotal: Int64 = 0
        for split in splits where split.categoryID == categoryID {
          let sum = splitTotal.addingReportingOverflow(split.amount)
          guard !sum.overflow else { throw FinanceError.invalid("Součet výdajů je příliš velký.") }
          splitTotal = sum.partialValue
        }
        amount = splitTotal
      } else {
        amount = transaction.categoryID == categoryID ? transaction.amount : 0
      }
      guard amount >= 0 else { throw FinanceError.invalid("Součet výdajů je příliš velký.") }
      let addition = result.addingReportingOverflow(amount)
      guard !addition.overflow else { throw FinanceError.invalid("Součet výdajů je příliš velký.") }
      result = addition.partialValue
    }
    return result
  }

  public static func recurringAmount(
    for payment: RecurringPayment, in state: Snapshot
  ) throws -> Int64 {
    guard let stored = state.recurringPayments.first(where: { $0.id == payment.id }),
      stored == payment
    else {
      throw FinanceError.invalid("Pravidelná platba nebyla nalezena.")
    }
    guard let loanID = payment.loanID else { return payment.amount }
    guard let loan = state.loans.first(where: { $0.id == loanID }) else {
      throw FinanceError.invalid("Plán splátky odkazuje na neexistující půjčku.")
    }
    return min(payment.amount, try remainingPrincipal(for: loan, transactions: state.transactions))
  }

  public static func recurringKind(
    for payment: RecurringPayment, in state: Snapshot
  ) throws -> TransactionKind {
    guard let stored = state.recurringPayments.first(where: { $0.id == payment.id }),
      stored == payment
    else {
      throw FinanceError.invalid("Pravidelná platba nebyla nalezena.")
    }
    guard let loanID = payment.loanID else { return .expense }
    guard let loan = state.loans.first(where: { $0.id == loanID }) else {
      throw FinanceError.invalid("Plán splátky odkazuje na neexistující půjčku.")
    }
    return loan.direction == .borrowed ? .expense : .income
  }

  public static func nextOccurrence(
    for payment: RecurringPayment, in state: Snapshot
  ) throws -> Day? {
    guard payment.isActive else { return nil }
    guard payment.amount > 0,
      payment.startDay.isValid,
      payment.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else { return nil }
    guard let stored = state.recurringPayments.first(where: { $0.id == payment.id }),
      stored == payment
    else { return nil }

    if payment.loanID != nil, try recurringAmount(for: payment, in: state) == 0 {
      return nil
    }

    let paid = Set(
      state.transactions.compactMap { transaction -> String? in
        guard transaction.recurringID == payment.id, let occurrence = transaction.occurrenceDay
        else { return nil }
        return occurrence.rawValue
      })
    let skipped = Set(payment.skippedOccurrences ?? [])
    let today = Day.today
    let maxIterations = 100_000
    for index in 0..<maxIterations {
      guard let occurrence = scheduledOccurrence(for: payment, index: index) else { return nil }
      if !paid.contains(occurrence.rawValue), !skipped.contains(occurrence) { return occurrence }
      if occurrence > today, index > 0 { return nil }
    }
    return nil
  }

  public static func skipMonthlyPayment(
    paymentID: UUID, occurrence: Day, in state: inout Snapshot
  ) throws {
    try validate(state)
    guard let index = state.recurringPayments.firstIndex(where: { $0.id == paymentID }) else {
      throw FinanceError.invalid("Pravidelná platba nebyla nalezena.")
    }
    let payment = state.recurringPayments[index]
    guard payment.isActive, payment.interval == .monthly,
      try recurringKind(for: payment, in: state) == .expense,
      occurrence <= .today, try nextOccurrence(for: payment, in: state) == occurrence
    else {
      throw FinanceError.invalid("Přeskočit lze jen nejbližší splatnou měsíční platbu.")
    }
    var candidate = state
    candidate.recurringPayments[index].skippedOccurrences =
      (payment.skippedOccurrences ?? []) + [occurrence]
    try validate(candidate)
    state = candidate
  }

  public static func restoreSkippedOccurrence(
    paymentID: UUID, occurrence: Day, in state: inout Snapshot
  ) throws {
    try validate(state)
    guard let index = state.recurringPayments.firstIndex(where: { $0.id == paymentID }),
      let skipped = state.recurringPayments[index].skippedOccurrences,
      skipped.contains(occurrence)
    else {
      throw FinanceError.invalid("Přeskočená platba nebyla nalezena.")
    }
    var candidate = state
    let remaining = skipped.filter { $0 != occurrence }
    candidate.recurringPayments[index].skippedOccurrences = remaining.isEmpty ? nil : remaining
    try validate(candidate)
    state = candidate
  }

  /// Converts a pending manual installment into a ledger receipt, or records an extra receipt.
  /// Previously paid manual records remain untouched and are never booked retroactively.
  public static func receiveLoanRepayment(
    loanID: UUID, installmentID: UUID? = nil, receiptID: UUID,
    accountID: UUID, amount: Int64, paidOn: Day, in state: inout Snapshot
  ) throws {
    try validate(state)
    guard let index = state.loans.firstIndex(where: { $0.id == loanID }),
      state.loans[index].direction == .lent
    else {
      throw FinanceError.invalid("Vyberte půjčku, kterou vám někdo splácí.")
    }
    guard !state.transactions.contains(where: { $0.id == receiptID }),
      !state.transactionHistory.contains(where: {
        $0.before?.id == receiptID || $0.after?.id == receiptID
      })
    else {
      throw FinanceError.invalid("Tato splátka už byla zaznamenána.")
    }
    guard let account = state.accounts.first(where: { $0.id == accountID }),
      account.kind == .standard, !account.isArchived
    else {
      throw FinanceError.invalid("Vyberte aktivní běžný účet.")
    }
    guard paidOn.isValid, paidOn <= .today else {
      throw FinanceError.invalid("Datum přijetí nesmí být v budoucnu.")
    }
    let loan = state.loans[index]
    guard amount > 0, amount <= (try remainingPrincipal(for: loan, in: state)) else {
      throw FinanceError.invalid("Zadejte kladnou částku nejvýše do zbývajícího dluhu.")
    }
    var candidate = state
    if let installmentID {
      guard let installment = loan.installments.first(where: { $0.id == installmentID }),
        installment.paidDay == nil
      else {
        throw FinanceError.invalid("Splátka už byla uhrazena nebo neexistuje.")
      }
      candidate.loans[index].installments.removeAll { $0.id == installmentID }
    }
    let category =
      candidate.categories.first { $0.name == "Splátky půjček" }
      ?? Category(name: "Splátky půjček", symbol: "person.2")
    if !candidate.categories.contains(where: { $0.id == category.id }) {
      candidate.categories.append(category)
    }
    candidate.transactions.append(
      Transaction(
        id: receiptID, kind: .income, amount: amount, day: paidOn, accountID: accountID,
        categoryID: category.id, note: "Splátka: \(loan.name)", loanID: loanID))
    try validate(candidate)
    state = candidate
  }

  public static func confirm(
    payment: RecurringPayment, occurrence: Day, paidOn: Day, amount: Int64, in state: inout Snapshot
  ) throws {
    try validate(state)
    guard payment.isActive,
      let stored = state.recurringPayments.first(where: { $0.id == payment.id }), stored == payment
    else {
      throw FinanceError.invalid("Pravidelná platba není aktivní nebo nebyla nalezena.")
    }
    if payment.loanID != nil {
      guard let account = state.accounts.first(where: { $0.id == payment.accountID }),
        account.kind == .standard, !account.isArchived
      else {
        throw FinanceError.invalid("Novou splátku půjčky lze potvrdit jen na aktivním běžném účtu.")
      }
    }
    try requireValid(occurrence, message: "Výskyt pravidelné platby obsahuje neplatné datum.")
    try requireValid(paidOn, message: "Datum úhrady je neplatné.")
    guard occurrence >= payment.startDay, isScheduled(occurrence, for: payment) else {
      throw FinanceError.invalid("Datum výskytu neodpovídá plánu pravidelné platby.")
    }
    guard occurrence <= Day.today else {
      throw FinanceError.invalid("Výskyt pravidelné platby nesmí být v budoucnu.")
    }
    guard paidOn <= Day.today else {
      throw FinanceError.invalid("Datum úhrady nesmí být v budoucnu.")
    }
    guard amount > 0 else { throw FinanceError.invalid("Částka úhrady musí být kladná.") }
    guard
      !state.transactions.contains(where: {
        $0.recurringID == payment.id && $0.occurrenceDay == occurrence
      })
    else {
      throw FinanceError.invalid("Tento výskyt pravidelné platby už byl potvrzen.")
    }

    let loan: Loan?
    if let loanID = payment.loanID {
      guard let storedLoan = state.loans.first(where: { $0.id == loanID }) else {
        throw FinanceError.invalid("Plán splátky odkazuje na neexistující půjčku.")
      }
      let remaining = try remainingPrincipal(for: storedLoan, transactions: state.transactions)
      guard amount <= remaining else {
        throw FinanceError.invalid("Částka splátky převyšuje zbývající jistinu.")
      }
      loan = storedLoan
    } else {
      loan = nil
    }

    var candidate = state
    candidate.transactions.append(
      Transaction(
        kind: loan.map { $0.direction == .borrowed ? .expense : .income } ?? .expense,
        amount: amount, day: paidOn, accountID: payment.accountID,
        categoryID: payment.categoryID, note: payment.name, recurringID: payment.id,
        occurrenceDay: occurrence, loanID: payment.loanID))
    try validate(candidate)
    state = candidate
  }

  /// Monthly outgoing plan: ordinary payments including annual subscriptions / 12,
  /// plus the next outgoing loan installments capped at the remaining principal.
  /// The snapshot must already be validated; this is not a total of payments due this month.
  public static func monthlyRecurringCost(in state: Snapshot) throws -> Int64 {
    let annual = try annualRecurringCost(in: state)
    let ordinaryMonthly = annual / 12 + (annual % 12 >= 6 ? 1 : 0)
    let loanPayments = try state.recurringPayments.compactMap { payment -> Int64? in
      guard payment.isActive, payment.loanID != nil,
        try recurringKind(for: payment, in: state) == .expense
      else { return nil }
      return try recurringAmount(for: payment, in: state)
    }
    return try Money.sum([ordinaryMonthly] + loanPayments)
  }

  public static func annualRecurringCost(in state: Snapshot) throws -> Int64 {
    return try annualRecurringCost(in: state, alreadyValidated: true)
  }

  private static func annualRecurringCost(in state: Snapshot, alreadyValidated: Bool) throws
    -> Int64
  {
    if !alreadyValidated { try validate(state) }
    var result: Int64 = 0
    for payment in state.recurringPayments where payment.isActive && payment.loanID == nil {
      guard payment.amount > 0 else {
        throw FinanceError.invalid("Částka pravidelné platby musí být kladná.")
      }
      let multiplier: Int64 = payment.interval == .monthly ? 12 : 1
      let product = payment.amount.multipliedReportingOverflow(by: multiplier)
      guard !product.overflow else {
        throw FinanceError.invalid("Roční náklad pravidelných plateb je příliš velký.")
      }
      let addition = result.addingReportingOverflow(product.partialValue)
      guard !addition.overflow else {
        throw FinanceError.invalid("Roční náklad pravidelných plateb je příliš velký.")
      }
      result = addition.partialValue
    }
    return result
  }

  private static func validateUniqueIDs(_ ids: [UUID], label: String) throws {
    guard Set(ids).count == ids.count else {
      throw FinanceError.invalid("Duplicitní ID v seznamu \(label).")
    }
  }

  private static func requireValid(_ day: Day, message: String) throws {
    guard day.isValid else { throw FinanceError.invalid(message) }
  }

  private static func requireValidMonth(_ month: String) throws {
    let parts = month.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 4, parts[1].count == 2,
      parts.allSatisfy({ $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
      let number = Int(parts[1]), (1...12).contains(number)
    else {
      throw FinanceError.invalid("Měsíc má neplatný formát.")
    }
    try requireValid(
      Day(rawValue: "\(parts[0])-\(parts[1])-01"), message: "Měsíc má neplatné datum.")
  }

  private static func add(_ amount: Int64, to dictionary: inout [String: Int64], key: String) throws
  {
    let current = dictionary[key, default: 0]
    let result = current.addingReportingOverflow(amount)
    guard !result.overflow else { throw FinanceError.invalid("Součet částek je příliš velký.") }
    dictionary[key] = result.partialValue
  }

  private static func checkedNegation(_ amount: Int64) throws -> Int64 {
    let result = Int64(0).subtractingReportingOverflow(amount)
    guard !result.overflow else { throw FinanceError.invalid("Částka je příliš velká.") }
    return result.partialValue
  }

  private static func validateAccountBalanceOverflow(_ state: Snapshot) throws {
    for account in state.accounts {
      var balance = account.openingBalance
      let relevant = state.transactions.filter { $0.day >= account.openingDay }
        .sorted { $0.day == $1.day ? $0.id.uuidString < $1.id.uuidString : $0.day < $1.day }
      for transaction in relevant {
        let delta: Int64?
        switch transaction.kind {
        case .expense: delta = transaction.accountID == account.id ? -transaction.amount : nil
        case .income: delta = transaction.accountID == account.id ? transaction.amount : nil
        case .adjustment: delta = transaction.accountID == account.id ? transaction.amount : nil
        case .transfer:
          if transaction.accountID == account.id {
            delta = -transaction.amount
          } else if transaction.destinationAccountID == account.id {
            delta = transaction.amount
          } else {
            delta = nil
          }
        }
        if let delta {
          let result = balance.addingReportingOverflow(delta)
          guard !result.overflow else {
            throw FinanceError.invalid("Zůstatek účtu je příliš velký.")
          }
          balance = result.partialValue
        }
      }
    }
  }

  private static func isScheduled(_ day: Day, for payment: RecurringPayment) -> Bool {
    guard let start = dateComponents(payment.startDay), let target = dateComponents(day) else {
      return false
    }
    switch payment.interval {
    case .monthly:
      let monthIndex = (target.year - start.year) * 12 + target.month - start.month
      guard monthIndex >= 0, let expected = scheduledOccurrence(for: payment, index: monthIndex)
      else { return false }
      return expected == day
    case .yearly:
      let yearIndex = target.year - start.year
      guard yearIndex >= 0, let expected = scheduledOccurrence(for: payment, index: yearIndex)
      else { return false }
      return expected == day
    }
  }

  public static func scheduledOccurrence(for payment: RecurringPayment, index: Int) -> Day? {
    guard let start = dateComponents(payment.startDay), index >= 0 else { return nil }
    let unit: Calendar.Component = payment.interval == .monthly ? .month : .year
    guard
      let base = calendar.date(from: DateComponents(year: start.year, month: start.month, day: 1)),
      let shifted = calendar.date(byAdding: unit, value: index, to: base)
    else { return nil }
    let shiftedComponents = calendar.dateComponents([.year, .month], from: shifted)
    guard let year = shiftedComponents.year, let month = shiftedComponents.month else { return nil }
    let maxDay = calendar.range(of: .day, in: .month, for: shifted)?.count ?? 0
    guard maxDay > 0 else { return nil }
    let day = min(start.day, maxDay)
    return Day(rawValue: String(format: "%04d-%02d-%02d", year, month, day))
  }

  private static func dateComponents(_ day: Day) -> (year: Int, month: Int, day: Int)? {
    let parts = day.rawValue.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]),
      let date = Int(parts[2])
    else { return nil }
    return (year, month, date)
  }
}
