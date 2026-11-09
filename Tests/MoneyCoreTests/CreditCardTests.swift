import XCTest

@testable import MoneyCore

final class CreditCardTests: XCTestCase {
  func testRepaymentUsesSelectedSourceAndRestoresDebtWhenTransferIsRemoved() throws {
    var snapshot = state(cardOpening: -250)
    let selected = Account(
      name: "Spoření", openingBalance: 50_000,
      openingDay: Day(rawValue: "2024-01-01"))
    snapshot.accounts.append(selected)
    try CreditCard.repay(cardID: cardID, from: selected.id, in: &snapshot)
    XCTAssertEqual(try Ledger.balance(account: selected, in: snapshot), 49_750)
    XCTAssertEqual(try Ledger.balance(account: snapshot.accounts[1], in: snapshot), 10_000)
    XCTAssertEqual(snapshot.transactions.last?.accountID, selected.id)
    XCTAssertEqual(
      try CreditCard.status(account: snapshot.accounts[0], in: snapshot).available, 1_000)
    snapshot.transactions.removeLast()
    XCTAssertEqual(try CreditCard.status(account: snapshot.accounts[0], in: snapshot).debt, 250)
    XCTAssertEqual(try Ledger.balance(account: selected, in: snapshot), 50_000)
  }

  private let cardID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
  private let sourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
  private let categoryID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!

  private func state(cardOpening: Int64 = 0, limit: Int64 = 1_000) -> Snapshot {
    var state = Snapshot()
    state.accounts = [
      Account(
        id: cardID, name: "Karta", openingBalance: cardOpening,
        openingDay: Day(rawValue: "2024-01-01"), kind: .creditCard, creditLimit: limit),
      Account(
        id: sourceID, name: "Běžný", openingBalance: 10_000,
        openingDay: Day(rawValue: "2024-01-01")),
    ]
    state.categories = [Category(id: categoryID, name: "Nákupy")]
    return state
  }

  func testExpenseCreatesDebtAndReducesAvailable() throws {
    var snapshot = state(limit: 1_000)
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 250, day: Day(rawValue: "2024-02-01"), accountID: cardID,
        categoryID: categoryID))

    let result = try CreditCard.status(account: snapshot.accounts[0], in: snapshot)
    XCTAssertEqual(result.debt, 250)
    XCTAssertEqual(result.available, 750)
    XCTAssertEqual(try Ledger.total(kind: .expense, month: "2024-02", in: snapshot), 250)
  }

  func testFullRepaymentIsTransferAndPreservesExpenseTotals() throws {
    var snapshot = state(limit: 1_000)
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 250, day: Day(rawValue: "2024-02-01"), accountID: cardID,
        categoryID: categoryID))
    let expenseTotal = try Ledger.total(kind: .expense, month: "2024-02", in: snapshot)

    try CreditCard.repay(cardID: cardID, from: sourceID, in: &snapshot)

    XCTAssertEqual(try CreditCard.status(account: snapshot.accounts[0], in: snapshot).debt, 0)
    XCTAssertEqual(try Ledger.total(kind: .expense, month: "2024-02", in: snapshot), expenseTotal)
    XCTAssertEqual(snapshot.transactions.last?.kind, .transfer)
    XCTAssertEqual(snapshot.transactions.last?.note, "Splacení kreditní karty Karta")
  }

  func testRepeatedRepaymentDoesNotMutate() throws {
    var snapshot = state()
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 250, day: Day(rawValue: "2024-02-01"), accountID: cardID,
        categoryID: categoryID))
    try CreditCard.repay(cardID: cardID, from: sourceID, in: &snapshot)
    let afterFirst = snapshot

    XCTAssertThrowsError(try CreditCard.repay(cardID: cardID, from: sourceID, in: &snapshot))
    XCTAssertEqual(snapshot, afterFirst)
  }

  func testHistoricalExpenseBeforeOpeningDoesNotAffectCard() throws {
    var snapshot = state(cardOpening: 100)
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 250, day: Day(rawValue: "2023-12-01"), accountID: cardID,
        categoryID: categoryID))

    XCTAssertEqual(try CreditCard.status(account: snapshot.accounts[0], in: snapshot).debt, 0)
  }

  func testOverLimitAndCreditBalanceAreReported() throws {
    var overLimit = state(limit: 100)
    overLimit.transactions.append(
      Transaction(
        kind: .expense, amount: 150, day: Day(rawValue: "2024-02-01"), accountID: cardID,
        categoryID: categoryID))
    let warning = try CreditCard.status(account: overLimit.accounts[0], in: overLimit)
    XCTAssertEqual(warning.overLimit, 50)
    XCTAssertEqual(warning.available, 0)

    let overpaid = state(cardOpening: 200, limit: 1_000)
    let balance = try CreditCard.status(account: overpaid.accounts[0], in: overpaid)
    XCTAssertEqual(balance.creditBalance, 200)
    XCTAssertEqual(balance.debt, 0)
    XCTAssertEqual(balance.available, 1_200)
  }

  func testInvalidKindsLimitsAndSourcesAreRejected() throws {
    var invalid = state(limit: 0)
    XCTAssertThrowsError(try Ledger.validate(invalid))
    invalid = state()
    invalid.accounts[0].creditLimit = nil
    XCTAssertThrowsError(try Ledger.validate(invalid))
    invalid = state()
    invalid.accounts[1].creditLimit = 100
    XCTAssertThrowsError(try Ledger.validate(invalid))
    XCTAssertThrowsError(try CreditCard.repay(cardID: cardID, from: cardID, in: &invalid))
  }

  func testOldAccountPayloadDefaultsToStandardWithoutCreditLimit() throws {
    let account = try JSONDecoder().decode(
      Account.self,
      from: Data(
        "{\"id\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"Starý\",\"openingBalance\":0,\"openingDay\":\"2024-01-01\",\"isArchived\":false}"
          .utf8))
    XCTAssertEqual(account.kind, .standard)
    XCTAssertNil(account.creditLimit)
  }

  func testUnrepresentableDebtOrAvailableThrows() throws {
    var debt = state(cardOpening: Int64.min)
    XCTAssertThrowsError(try CreditCard.status(account: debt.accounts[0], in: debt))

    debt = state(cardOpening: Int64.max, limit: 1)
    XCTAssertThrowsError(try CreditCard.status(account: debt.accounts[0], in: debt))
  }

  func testFailedRepaymentDoesNotMutateState() throws {
    var snapshot = state()
    snapshot.transactions.append(
      Transaction(
        kind: .expense, amount: 250, day: Day(rawValue: "2024-02-01"), accountID: cardID,
        categoryID: categoryID))
    snapshot.accounts[1].isArchived = true
    let original = snapshot

    XCTAssertThrowsError(try CreditCard.repay(cardID: cardID, from: sourceID, in: &snapshot))
    XCTAssertEqual(snapshot, original)
  }
}
