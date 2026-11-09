import Foundation

extension CategoryTotal {
  public func share(of total: Int64) -> Decimal {
    guard total > 0 else { return 0 }
    return Decimal(amount) / Decimal(total)
  }
}

/// A category-level portion of an expense transaction.
public struct SpendingPayment: Identifiable, Sendable {
  public let transaction: Transaction
  public let amount: Int64

  public var id: UUID { transaction.id }

  public init(transaction: Transaction, amount: Int64) {
    self.transaction = transaction
    self.amount = amount
  }
}

/// Transactions and category portions used by the spending drill-down.
public struct SpendingDetails: Sendable {
  public let incomeByDay: [Day: Int64]
  public let repaymentsByDay: [Day: Int64]
  public let expenses: [Transaction]
  public let categoryPayments: [UUID: [SpendingPayment]]
  public let transfers: [Transaction]
  public let creditRepayments: [Transaction]
  public let transferTotal: Int64
  public let creditRepaymentTotal: Int64

  public static func isCreditRepayment(
    _ transaction: Transaction, accountKinds: [UUID: AccountKind]
  ) -> Bool {
    transaction.kind == .transfer
      && accountKinds[transaction.accountID] == .standard
      && transaction.destinationAccountID.flatMap({ accountKinds[$0] }) == .creditCard
  }

  public static func make(state: Snapshot, start: Day, end: Day) throws -> SpendingDetails {
    guard start.isValid, end.isValid, start <= end else {
      throw FinanceError.invalid("Období výdajů není platné.")
    }

    let accountKinds = Dictionary(uniqueKeysWithValues: state.accounts.map { ($0.id, $0.kind) })
    let inPeriod = state.transactions.filter { $0.day >= start && $0.day <= end }
    let expenses = inPeriod.filter { $0.kind == .expense }
      .sorted(by: transactionSort)
    let allTransfers = inPeriod.filter { $0.kind == .transfer }
    let creditRepayments = allTransfers.filter { isCreditRepayment($0, accountKinds: accountKinds) }
      .sorted(by: transactionSort)
    let transfers = allTransfers.filter { !isCreditRepayment($0, accountKinds: accountKinds) }
      .sorted(by: transactionSort)

    var categoryPayments: [UUID: [SpendingPayment]] = [:]
    for transaction in expenses {
      let portions: [(UUID, Int64)]
      if let splits = transaction.splits {
        portions = try groupedSplits(splits)
      } else if let categoryID = transaction.categoryID {
        portions = [(categoryID, transaction.amount)]
      } else {
        portions = []
      }
      for (categoryID, amount) in portions {
        categoryPayments[categoryID, default: []].append(
          SpendingPayment(transaction: transaction, amount: amount))
      }
    }
    for categoryID in categoryPayments.keys {
      categoryPayments[categoryID]?.sort { paymentSort($0, $1) }
    }

    return SpendingDetails(
      incomeByDay: try dailyAmounts(inPeriod.filter { $0.kind == .income }),
      repaymentsByDay: try dailyAmounts(creditRepayments),
      expenses: expenses,
      categoryPayments: categoryPayments,
      transfers: transfers,
      creditRepayments: creditRepayments,
      transferTotal: try Money.sum(transfers.map(\.amount)),
      creditRepaymentTotal: try Money.sum(creditRepayments.map(\.amount)))
  }

  public static func make(state: Snapshot, month: String) throws -> SpendingDetails {
    let first = Day(rawValue: "\(month)-01")
    guard month.count == 7, first.isValid, first.month == month else {
      throw FinanceError.invalid("Měsíc výdajů není platný.")
    }
    let calendar = Calendar(identifier: .gregorian)
    guard let nextMonth = calendar.date(byAdding: .month, value: 1, to: first.date),
      let lastDate = calendar.date(byAdding: .day, value: -1, to: nextMonth)
    else { throw FinanceError.invalid("Měsíc výdajů není platný.") }
    return try make(state: state, start: first, end: Day(lastDate))
  }

  private static func dailyAmounts(_ transactions: [Transaction]) throws -> [Day: Int64] {
    try Dictionary(grouping: transactions, by: \.day).mapValues { try Money.sum($0.map(\.amount)) }
  }

  private static func groupedSplits(_ splits: [TransactionSplit]) throws -> [(UUID, Int64)] {
    var grouped: [UUID: Int64] = [:]
    for split in splits {
      grouped[split.categoryID] = try Money.sum([grouped[split.categoryID] ?? 0, split.amount])
    }
    return grouped.map { ($0.key, $0.value) }.sorted { $0.0.uuidString < $1.0.uuidString }
  }

  private static func transactionSort(_ lhs: Transaction, _ rhs: Transaction) -> Bool {
    lhs.amount == rhs.amount
      ? (lhs.day == rhs.day ? lhs.id.uuidString < rhs.id.uuidString : lhs.day > rhs.day)
      : lhs.amount > rhs.amount
  }

  private static func paymentSort(_ lhs: SpendingPayment, _ rhs: SpendingPayment) -> Bool {
    lhs.transaction.day == rhs.transaction.day
      ? lhs.transaction.id.uuidString < rhs.transaction.id.uuidString
      : lhs.transaction.day > rhs.transaction.day
  }
}
