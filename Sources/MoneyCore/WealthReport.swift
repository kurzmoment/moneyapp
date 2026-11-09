import Foundation

public struct LoanTotals: Sendable {
  public let borrowed: Int64
  public let lent: Int64

  public static func make(loans: [Loan], transactions: [Transaction] = []) throws -> LoanTotals {
    var borrowed: [Int64] = []
    var lent: [Int64] = []
    for loan in loans {
      let remaining = try Ledger.remainingPrincipal(for: loan, transactions: transactions)
      if loan.direction == .borrowed { borrowed.append(remaining) } else { lent.append(remaining) }
    }
    return LoanTotals(borrowed: try Money.sum(borrowed), lent: try Money.sum(lent))
  }

  public static func make(in state: Snapshot) throws -> LoanTotals {
    return try make(loans: state.loans, transactions: state.transactions)
  }
}

public struct InvestmentSummary: Sendable {
  public let deposits: Int64
  public let withdrawals: Int64
  public let difference: Int64
  public let hasRecordedDeposits: Bool
  public let hasLaterMovements: Bool

  public static func make(portfolio: InvestmentPortfolio) throws -> InvestmentSummary {
    let relevant = portfolio.entries.filter { $0.day <= portfolio.valuedOn }
    let deposits = relevant.filter { $0.kind == .deposit }
    return InvestmentSummary(
      deposits: try Money.sum(deposits.map(\.amount)),
      withdrawals: try Money.sum(relevant.filter { $0.kind == .withdrawal }.map(\.amount)),
      difference: try portfolio.performance(),
      hasRecordedDeposits: !deposits.isEmpty,
      hasLaterMovements: portfolio.entries.contains { $0.day > portfolio.valuedOn })
  }
}
