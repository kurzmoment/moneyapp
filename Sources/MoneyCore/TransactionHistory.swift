import Foundation

public enum TransactionHistory {
  public static func recordChanges(
    from previous: Snapshot, in next: inout Snapshot, date: Date = Date()
  ) {
    let old = Dictionary(uniqueKeysWithValues: previous.transactions.map { ($0.id, $0) })
    let new = Dictionary(uniqueKeysWithValues: next.transactions.map { ($0.id, $0) })
    for id in Set(old.keys).union(new.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
      if old[id] != new[id] {
        next.transactionHistory.append(
          TransactionChange(date: date, before: old[id], after: new[id]))
      }
    }
  }

  public static func undo(_ changeID: UUID, in state: inout Snapshot) throws {
    guard let index = state.transactionHistory.firstIndex(where: { $0.id == changeID }),
      !state.transactionHistory[index].reverted
    else {
      throw FinanceError.invalid("Tato změna už byla vrácena nebo není v historii.")
    }
    let change = state.transactionHistory[index]
    guard let id = change.after?.id ?? change.before?.id,
      state.transactions.first(where: { $0.id == id }) == change.after
    else {
      throw FinanceError.invalid("Transakce se mezitím změnila. Nejprve vraťte její novější změnu.")
    }
    if state.transactionHistory.dropFirst(index + 1).contains(where: {
      !$0.reverted && ($0.after?.id ?? $0.before?.id) == id
    }) {
      throw FinanceError.invalid("Nejprve vraťte novější změnu této transakce.")
    }
    var next = state
    next.transactions.removeAll { $0.id == id }
    if let original = change.before { next.transactions.append(original) }
    next.transactionHistory[index].reverted = true
    next.transactionHistory[index].revertedAt = Date()
    try Ledger.validate(next)
    state = next
  }

  public static func checkNeedsReview(_ check: BalanceCheck, in state: Snapshot) throws -> Bool {
    guard let account = state.accounts.first(where: { $0.id == check.accountID }),
      account.openingDay <= check.day
    else { return true }
    if try Ledger.balance(account: account, in: state, through: check.day) != check.balance {
      return true
    }
    return state.transactionHistory.contains { change in
      max(change.date, change.revertedAt ?? change.date) > check.checkedAt
        && [change.before, change.after].compactMap { $0 }.contains {
          $0.day <= check.day
            && ($0.accountID == check.accountID || $0.destinationAccountID == check.accountID)
        }
    }
  }
}
