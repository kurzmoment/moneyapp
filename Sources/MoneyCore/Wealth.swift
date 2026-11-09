import Foundation

public enum LoanDirection: String, Codable, CaseIterable, Sendable {
  case borrowed
  case lent

  public var title: String {
    switch self {
    case .borrowed: "Dlužím"
    case .lent: "Dluží mi"
    }
  }
}

/// A planned repayment. Its amount counts towards the debt only after `paidDay` is set.
public struct LoanInstallment: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var amount: Int64
  public var dueDay: Day
  public var paidDay: Day?

  public init(
    id: UUID = UUID(), amount: Int64, dueDay: Day, paidDay: Day? = nil
  ) {
    self.id = id
    self.amount = amount
    self.dueDay = dueDay
    self.paidDay = paidDay
  }
}

public struct Loan: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var direction: LoanDirection
  public var principal: Int64
  public var startDay: Day
  public var dueDay: Day?
  public var installments: [LoanInstallment]

  public init(
    id: UUID = UUID(), name: String, direction: LoanDirection, principal: Int64,
    startDay: Day, dueDay: Day? = nil, installments: [LoanInstallment] = []
  ) {
    self.id = id
    self.name = name
    self.direction = direction
    self.principal = principal
    self.startDay = startDay
    self.dueDay = dueDay
    self.installments = installments
  }

  public func remainingPrincipal() throws -> Int64 {
    try Ledger.remainingPrincipal(for: self)
  }

  public mutating func addInstallment(_ installment: LoanInstallment) throws {
    var candidate = self
    candidate.installments.append(installment)
    try Ledger.validate(candidate)
    self = candidate
  }

  public mutating func setPaidDay(_ paidDay: Day?, for installmentID: UUID) throws {
    guard let index = installments.firstIndex(where: { $0.id == installmentID }) else {
      throw FinanceError.invalid("Splátka nebyla nalezena.")
    }
    var candidate = self
    candidate.installments[index].paidDay = paidDay
    try Ledger.validate(candidate)
    self = candidate
  }
}

public enum InvestmentEntryKind: String, Codable, CaseIterable, Sendable {
  case deposit
  case withdrawal

  public var title: String {
    switch self {
    case .deposit: "Vklad"
    case .withdrawal: "Výběr"
    }
  }
}

public struct InvestmentEntry: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var kind: InvestmentEntryKind
  public var amount: Int64
  public var day: Day

  public init(
    id: UUID = UUID(), kind: InvestmentEntryKind, amount: Int64, day: Day
  ) {
    self.id = id
    self.kind = kind
    self.amount = amount
    self.day = day
  }
}

public struct InvestmentPortfolio: Identifiable, Codable, Equatable, Sendable {
  public var id: UUID
  public var name: String
  public var entries: [InvestmentEntry]
  public var currentValue: Int64
  public var valuedOn: Day

  public init(
    id: UUID = UUID(), name: String, entries: [InvestmentEntry] = [], currentValue: Int64,
    valuedOn: Day
  ) {
    self.id = id
    self.name = name
    self.entries = entries
    self.currentValue = currentValue
    self.valuedOn = valuedOn
  }

  /// Performance at the valuation date. Movements entered after that date are excluded.
  public func performance() throws -> Int64 {
    try Ledger.performance(of: self)
  }

  public mutating func addEntry(_ entry: InvestmentEntry) throws {
    var candidate = self
    candidate.entries.append(entry)
    try Ledger.validate(candidate)
    self = candidate
  }

  public mutating func updateValuation(currentValue: Int64, valuedOn: Day) throws {
    var candidate = self
    candidate.currentValue = currentValue
    candidate.valuedOn = valuedOn
    try Ledger.validate(candidate)
    self = candidate
  }
}
