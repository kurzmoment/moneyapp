import Foundation

public struct CreditCardStatus: Sendable, Equatable {
  public let debt: Int64
  public let available: Int64
  public let creditBalance: Int64
  public let overLimit: Int64

  public init(debt: Int64, available: Int64, creditBalance: Int64, overLimit: Int64) {
    self.debt = debt
    self.available = available
    self.creditBalance = creditBalance
    self.overLimit = overLimit
  }
}

public enum CreditCard {
  public static func status(account: Account, in state: Snapshot) throws -> CreditCardStatus {
    guard let stored = state.accounts.first(where: { $0.id == account.id }), stored == account
    else {
      throw FinanceError.invalid("Účet nebyl nalezen.")
    }
    guard stored.kind == .creditCard, let limit = stored.creditLimit else {
      throw FinanceError.invalid("Účet není kreditní karta.")
    }

    let balance = try Ledger.balance(account: stored, in: state)
    return try status(balance: balance, limit: limit)
  }

  static func status(balance: Int64, limit: Int64) throws -> CreditCardStatus {
    guard limit > 0 else {
      throw FinanceError.invalid("Kreditní karta musí mít kladný úvěrový limit.")
    }
    let debt: Int64
    if balance < 0 {
      debt = try Money.subtract(0, balance)
    } else {
      debt = 0
    }
    let creditBalance = max(balance, 0)
    let available = max(try Money.sum([limit, balance]), 0)
    let overLimit = max(try Money.subtract(debt, limit), 0)
    return CreditCardStatus(
      debt: debt, available: available, creditBalance: creditBalance, overLimit: overLimit)
  }

  public static func repay(cardID: UUID, from sourceID: UUID, in state: inout Snapshot) throws {
    try Ledger.validate(state)
    guard let card = state.accounts.first(where: { $0.id == cardID }), !card.isArchived,
      card.kind == .creditCard
    else { throw FinanceError.invalid("Kreditní karta nebyla nalezena nebo není aktivní.") }
    guard let source = state.accounts.first(where: { $0.id == sourceID }), !source.isArchived,
      source.kind == .standard, source.id != card.id
    else { throw FinanceError.invalid("Zdrojový účet musí být jiný aktivní běžný účet.") }

    let currentStatus = try status(account: card, in: state)
    guard currentStatus.debt > 0 else {
      throw FinanceError.invalid("Kreditní karta nemá žádný dluh.")
    }

    var candidate = state
    candidate.transactions.append(
      Transaction(
        kind: .transfer,
        amount: currentStatus.debt,
        day: .today,
        accountID: source.id,
        destinationAccountID: card.id,
        note: "Splacení kreditní karty \(card.name)"))
    try Ledger.validate(candidate)
    state = candidate
  }
}
