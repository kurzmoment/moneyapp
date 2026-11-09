import Foundation

public enum FinanceError: Error, LocalizedError, Equatable {
  case invalid(String)
  public var errorDescription: String? {
    switch self {
    case .invalid(let message): message
    }
  }
}

/// Calendar-only ISO date. Construct via parsing or a user's local calendar date.
public struct Day: RawRepresentable, Codable, Hashable, Comparable, Sendable {
  private static var calendar: Calendar { Calendar(identifier: .gregorian) }
  public let rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }
  public init(_ date: Date = Date()) {
    let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
    rawValue = String(
      format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
  }
  public static func < (lhs: Day, rhs: Day) -> Bool { lhs.rawValue < rhs.rawValue }
  public static var today: Day { Day() }
  public var month: String { String(rawValue.prefix(7)) }
  public var date: Date {
    let values = rawValue.split(separator: "-").compactMap { Int($0) }
    guard values.count == 3 else { return Date(timeIntervalSince1970: 0) }
    return Self.calendar.date(
      from: DateComponents(year: values[0], month: values[1], day: values[2], hour: 12))
      ?? Date(timeIntervalSince1970: 0)
  }
  public var isValid: Bool {
    let parts = rawValue.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
      parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
      let year = Int(parts[0]), (1...9999).contains(year)
    else { return false }
    return Day(date).rawValue == rawValue
  }
}

public struct Account: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var openingBalance: Int64
  public var openingDay: Day
  public var isArchived: Bool
  public var kind: AccountKind
  public var creditLimit: Int64?

  private enum CodingKeys: String, CodingKey {
    case id, name, openingBalance, openingDay, isArchived, kind, creditLimit
  }

  public init(
    id: UUID = UUID(), name: String, openingBalance: Int64, openingDay: Day,
    isArchived: Bool = false, kind: AccountKind = .standard, creditLimit: Int64? = nil
  ) {
    self.id = id
    self.name = name
    self.openingBalance = openingBalance
    self.openingDay = openingDay
    self.isArchived = isArchived
    self.kind = kind
    self.creditLimit = creditLimit
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try values.decode(UUID.self, forKey: .id)
    self.name = try values.decode(String.self, forKey: .name)
    self.openingBalance = try values.decode(Int64.self, forKey: .openingBalance)
    self.openingDay = try values.decode(Day.self, forKey: .openingDay)
    self.isArchived = try values.decode(Bool.self, forKey: .isArchived)
    self.kind = try values.decodeIfPresent(AccountKind.self, forKey: .kind) ?? .standard
    self.creditLimit = try values.decodeIfPresent(Int64.self, forKey: .creditLimit)
  }
}

public enum AccountKind: String, Codable, CaseIterable, Sendable {
  case standard
  case creditCard

  public var title: String {
    switch self {
    case .standard: "Běžný účet"
    case .creditCard: "Kreditní karta"
    }
  }
}

public enum TransactionKind: String, Codable, CaseIterable, Sendable {
  case expense, income, transfer, adjustment
  public var title: String {
    switch self {
    case .expense: "Výdaj"
    case .income: "Příjem"
    case .transfer: "Převod"
    case .adjustment: "Dorovnání"
    }
  }
}

public struct Category: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var symbol: String
  public init(id: UUID = UUID(), name: String, symbol: String = "tag") {
    self.id = id
    self.name = name
    self.symbol = symbol
  }
}

public struct Transaction: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var kind: TransactionKind
  /// Positive for ordinary movements; signed for a balance adjustment.
  public var amount: Int64
  public var day: Day
  public var accountID: UUID
  public var destinationAccountID: UUID?
  public var categoryID: UUID?
  public var note: String
  public var recurringID: UUID?
  public var occurrenceDay: Day?
  /// The loan whose repayment this transaction records, when applicable.
  public var loanID: UUID?
  public var splits: [TransactionSplit]?
  /// True marks an income as salary. Nil keeps compatibility with older data.
  public var isSalary: Bool?
  public init(
    id: UUID = UUID(), kind: TransactionKind, amount: Int64, day: Day, accountID: UUID,
    destinationAccountID: UUID? = nil, categoryID: UUID? = nil, note: String = "",
    recurringID: UUID? = nil, occurrenceDay: Day? = nil, loanID: UUID? = nil,
    splits: [TransactionSplit]? = nil,
    isSalary: Bool? = nil
  ) {
    self.id = id
    self.kind = kind
    self.amount = amount
    self.day = day
    self.accountID = accountID
    self.destinationAccountID = destinationAccountID
    self.categoryID = categoryID
    self.note = note
    self.recurringID = recurringID
    self.occurrenceDay = occurrenceDay
    self.loanID = loanID
    self.splits = splits
    self.isSalary = isSalary
  }
}

public struct TransactionSplit: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var categoryID: UUID
  public var amount: Int64

  public init(id: UUID = UUID(), categoryID: UUID, amount: Int64) {
    self.id = id
    self.categoryID = categoryID
    self.amount = amount
  }
}

public struct SavingsGoal: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var target: Int64
  public var saved: Int64

  public init(id: UUID = UUID(), name: String, target: Int64, saved: Int64 = 0) {
    self.id = id
    self.name = name
    self.target = target
    self.saved = saved
  }
}

public struct BalanceCheck: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var accountID: UUID
  public var day: Day
  public var balance: Int64
  public var checkedAt: Date

  public init(
    id: UUID = UUID(), accountID: UUID, day: Day, balance: Int64, checkedAt: Date = Date()
  ) {
    self.id = id
    self.accountID = accountID
    self.day = day
    self.balance = balance
    self.checkedAt = checkedAt
  }
}

public struct TransactionChange: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var date: Date
  public var before: Transaction?
  public var after: Transaction?
  public var reverted: Bool
  public var revertedAt: Date?

  public init(
    id: UUID = UUID(), date: Date = Date(), before: Transaction? = nil, after: Transaction? = nil,
    reverted: Bool = false, revertedAt: Date? = nil
  ) {
    self.id = id
    self.date = date
    self.before = before
    self.after = after
    self.reverted = reverted
    self.revertedAt = revertedAt
  }
}

public struct Budget: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var categoryID: UUID
  public var month: String
  public var limit: Int64
  public init(id: UUID = UUID(), categoryID: UUID, month: String, limit: Int64) {
    self.id = id
    self.categoryID = categoryID
    self.month = month
    self.limit = limit
  }
}

public enum RepeatInterval: String, Codable, CaseIterable, Sendable {
  case monthly, yearly
  public var title: String { self == .monthly ? "Měsíčně" : "Ročně" }
}

public struct RecurringPayment: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var amount: Int64
  public var accountID: UUID
  public var categoryID: UUID
  public var startDay: Day
  public var interval: RepeatInterval
  public var isActive: Bool
  /// When set, this recurring payment is the repayment schedule for a loan.
  public var loanID: UUID?
  /// Scheduled monthly occurrences explicitly skipped without a financial transaction.
  public var skippedOccurrences: [Day]?
  public init(
    id: UUID = UUID(), name: String, amount: Int64, accountID: UUID, categoryID: UUID,
    startDay: Day, interval: RepeatInterval, isActive: Bool = true, loanID: UUID? = nil,
    skippedOccurrences: [Day]? = nil
  ) {
    self.id = id
    self.name = name
    self.amount = amount
    self.accountID = accountID
    self.categoryID = categoryID
    self.startDay = startDay
    self.interval = interval
    self.isActive = isActive
    self.loanID = loanID
    self.skippedOccurrences = skippedOccurrences
  }
}

public struct Snapshot: Codable, Equatable, Sendable {
  public var schemaVersion: Int = 6
  public var accounts: [Account] = []
  public var categories: [Category] = []
  public var transactions: [Transaction] = []
  public var budgets: [Budget] = []
  public var recurringPayments: [RecurringPayment] = []
  public var savingsGoals: [SavingsGoal] = []
  public var balanceChecks: [BalanceCheck] = []
  public var transactionHistory: [TransactionChange] = []
  public var loans: [Loan] = []
  public var investments: [InvestmentPortfolio] = []
  public init() {}

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, accounts, categories, transactions, budgets, recurringPayments
    case savingsGoals, balanceChecks, transactionHistory, loans, investments
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
    accounts = try values.decode([Account].self, forKey: .accounts)
    categories = try values.decode([Category].self, forKey: .categories)
    transactions = try values.decode([Transaction].self, forKey: .transactions)
    budgets = try values.decode([Budget].self, forKey: .budgets)
    recurringPayments =
      try values.decode([RecurringPayment].self, forKey: .recurringPayments)
    if schemaVersion >= 3 {
      savingsGoals = try values.decode([SavingsGoal].self, forKey: .savingsGoals)
      balanceChecks = try values.decode([BalanceCheck].self, forKey: .balanceChecks)
      transactionHistory = try values.decode([TransactionChange].self, forKey: .transactionHistory)
    } else {
      savingsGoals = []
      balanceChecks = []
      transactionHistory = []
    }
    if schemaVersion >= 4 {
      loans = try values.decode([Loan].self, forKey: .loans)
      investments = try values.decode([InvestmentPortfolio].self, forKey: .investments)
    } else {
      loans = []
      investments = []
    }
  }
  public static var empty: Snapshot {
    var state = Snapshot()
    state.categories = [
      ("Potraviny", "basket"), ("Bydlení", "house"), ("Doprava", "tram"),
      ("Restaurace", "fork.knife"), ("Volný čas", "sparkles"), ("Zdraví", "heart"),
      ("Nákupy", "bag"), ("Předplatná", "repeat"), ("Mzda", "briefcase"), ("Ostatní", "tag"),
    ].map { Category(name: $0.0, symbol: $0.1) }
    return state
  }
}
