import AppKit
import Foundation
import MoneyCore
import OSLog
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class AppModel {
  var state = Snapshot()
  var busy = false
  var loaded = false
  var errorMessage: String?
  var statusMessage: String?
  var month = Day.today.month
  var report = MonthlyReport.empty
  let isDemo: Bool
  private var store: SQLiteStore?
  private let logger = Logger(subsystem: "cz.moneyapp.desktop", category: "Storage")
  private let storageURL: URL

  init() {
    isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
    let base = URL.applicationSupportDirectory.appendingPathComponent("MoneyApp", isDirectory: true)
    storageURL =
      isDemo
      ? URL.temporaryDirectory.appendingPathComponent("MoneyApp-Demo-\(UUID().uuidString).sqlite")
      : base.appendingPathComponent("finance.sqlite")
  }

  func load() async {
    guard !busy else { return }
    busy = true
    defer { busy = false }
    do {
      let url = storageURL
      let repository = try await Task.detached {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try SQLiteStore(url: url)
      }.value
      if isDemo { try await repository.save(DemoData.make()) }
      let snapshot = try await repository.load()
      try Ledger.validate(snapshot)
      state = snapshot
      store = repository
      loaded = true
      refreshReport()
      if !isDemo {
        do {
          try await repository.dailyBackup(
            directory: url.deletingLastPathComponent().appendingPathComponent("Backups"))
        } catch {
          logger.error("Daily backup failed")
          errorMessage =
            "Data jsou načtená, ale automatická záloha se nezdařila: \(error.localizedDescription)"
        }
      }
    } catch {
      logger.error("Opening finance storage failed")
      errorMessage =
        "Data se nepodařilo otevřít. Nic nebylo přepsáno. \(error.localizedDescription)"
    }
  }

  private func commit(_ proposed: Snapshot, recordHistory: Bool = true) async throws {
    var next = proposed
    if recordHistory { TransactionHistory.recordChanges(from: state, in: &next) }
    guard !busy, let store else {
      throw FinanceError.invalid("Počkejte na dokončení předchozí operace.")
    }
    try Ledger.validate(next)
    // Check report arithmetic before making a state durable.
    _ = try MonthlyReport.make(state: next, month: month)
    if let period = SalaryPeriodReport.availablePeriods(in: next).last {
      _ = try SalaryPeriodReport.make(state: next, period: period)
    }
    busy = true
    defer { busy = false }
    try await store.save(next)
    state = next
    refreshReport()
    statusMessage = "Uloženo do tohoto Macu"
  }

  func saveAccount(_ account: Account) async throws {
    if let original = state.accounts.first(where: { $0.id == account.id }),
      original.kind == .creditCard, account.kind != .creditCard
    {
      throw FinanceError.invalid(
        "Kreditní kartu nelze změnit na běžný účet. Vytvořte nový běžný účet.")
    }
    var next = state
    Self.upsert(account, into: &next.accounts)
    try await commit(next)
    logger.info("Saved account \(account.id.uuidString, privacy: .public)")
  }

  func repayCreditCard(_ card: Account, from sourceID: UUID) async throws {
    var next = state
    try CreditCard.repay(cardID: card.id, from: sourceID, in: &next)
    try await commit(next)
    statusMessage = "Splacení kreditní karty bylo zapsáno jako převod"
    logger.info("Recorded credit card repayment \(card.id.uuidString, privacy: .public)")
  }

  func saveTransaction(_ transaction: Transaction) async throws {
    let original = state.transactions.first { $0.id == transaction.id }
    guard transaction.loanID == original?.loanID else {
      throw FinanceError.invalid(
        "Vazbu splátky na půjčku nelze změnit. Novou splátku potvrďte v Pravidelných platbách.")
    }
    if original?.loanID != nil {
      guard transaction.recurringID == original?.recurringID,
        transaction.occurrenceDay == original?.occurrenceDay
      else {
        throw FinanceError.invalid("Výskyt potvrzené splátky nelze změnit.")
      }
    }
    var next = state
    Self.upsert(transaction, into: &next.transactions)
    try await commit(next)
    logger.info("Saved transaction \(transaction.id.uuidString, privacy: .public)")
  }

  func deleteTransaction(_ transaction: Transaction) async throws {
    var next = state
    next.transactions.removeAll { $0.id == transaction.id }
    try await commit(next)
    logger.info("Deleted transaction \(transaction.id.uuidString, privacy: .public)")
  }

  func saveBudget(_ budget: Budget) async throws {
    var next = state
    Self.upsert(budget, into: &next.budgets)
    try await commit(next)
  }

  func deleteBudget(_ budget: Budget) async throws {
    var next = state
    next.budgets.removeAll { $0.id == budget.id }
    try await commit(next)
  }

  func saveRecurring(_ payment: RecurringPayment) async throws {
    if let original = state.recurringPayments.first(where: { $0.id == payment.id }),
      original.loanID != payment.loanID
    {
      throw FinanceError.invalid("Vazbu uložené pravidelné platby na půjčku nelze změnit.")
    }
    if let original = state.recurringPayments.first(where: { $0.id == payment.id }),
      state.transactions.contains(where: { $0.recurringID == payment.id })
        || !(original.skippedOccurrences ?? []).isEmpty,
      original.startDay != payment.startDay || original.interval != payment.interval
    {
      throw FinanceError.invalid(
        payment.loanID == nil
          ? "Platba už má historii úhrad nebo přeskočení. Pro jiné datum nebo opakování ji pozastavte a vytvořte novou."
          : "Splátkový plán už má historii úhrad nebo přeskočení. První datum a opakování nelze změnit; částku a účet upravit můžete."
      )
    }
    var next = state
    var saved = payment
    // Editing amount/account must not discard skipped dates, including stale editor state.
    saved.skippedOccurrences =
      state.recurringPayments.first { $0.id == payment.id }?.skippedOccurrences
    Self.upsert(saved, into: &next.recurringPayments)
    try await commit(next)
  }

  func skipRecurring(_ payment: RecurringPayment, occurrence: Day) async throws {
    var next = state
    try Ledger.skipMonthlyPayment(paymentID: payment.id, occurrence: occurrence, in: &next)
    try await commit(next)
    statusMessage = "Platba k \(displayDate(occurrence)) byla přeskočena bez úhrady"
    logger.info("Skipped recurring payment \(payment.id.uuidString, privacy: .public)")
  }

  func restoreSkippedRecurring(_ payment: RecurringPayment, occurrence: Day) async throws {
    var next = state
    try Ledger.restoreSkippedOccurrence(paymentID: payment.id, occurrence: occurrence, in: &next)
    try await commit(next)
    statusMessage = "Přeskočená platba byla vrácena k úhradě"
    logger.info("Restored skipped recurring payment \(payment.id.uuidString, privacy: .public)")
  }

  func confirmRecurring(_ payment: RecurringPayment, occurrence: Day, paidOn: Day, amount: Int64)
    async throws
  {
    var next = state
    try Ledger.confirm(
      payment: payment, occurrence: occurrence, paidOn: paidOn, amount: amount, in: &next)
    try await commit(next)
    logger.info("Confirmed recurring payment \(payment.id.uuidString, privacy: .public)")
  }

  func reconcile(account: Account, target: Int64, day: Day, note: String) async throws {
    let balance = try Ledger.balance(account: account, in: state, through: day)
    let difference = try Money.subtract(target, balance)
    guard difference != 0 else {
      throw FinanceError.invalid("Zůstatek už odpovídá. Dorovnání není potřeba.")
    }
    try await saveTransaction(
      Transaction(
        kind: .adjustment, amount: difference, day: day, accountID: account.id, note: note))
  }

  func saveCategory(_ category: MoneyCore.Category) async throws {
    var next = state
    Self.upsert(category, into: &next.categories)
    try await commit(next)
  }

  func deleteCategory(_ category: MoneyCore.Category) async throws {
    guard
      !state.transactions.contains(where: {
        $0.categoryID == category.id
          || ($0.splits ?? []).contains(where: { $0.categoryID == category.id })
      }),
      !state.budgets.contains(where: { $0.categoryID == category.id }),
      !state.recurringPayments.contains(where: { $0.categoryID == category.id })
    else {
      throw FinanceError.invalid(
        "Kategorie se používá v transakcích, rozpočtech nebo pravidelných platbách. Můžete ji přejmenovat."
      )
    }
    var next = state
    next.categories.removeAll { $0.id == category.id }
    try await commit(next)
  }

  func receiveLoanRepayment(
    loanID: UUID, installmentID: UUID?, receiptID: UUID,
    accountID: UUID, amount: Int64, paidOn: Day
  ) async throws {
    var next = state
    try Ledger.receiveLoanRepayment(
      loanID: loanID, installmentID: installmentID, receiptID: receiptID,
      accountID: accountID, amount: amount, paidOn: paidOn, in: &next)
    try await commit(next)
    statusMessage = "Splátka byla připsána na běžný účet"
    logger.info("Received loan repayment \(loanID.uuidString, privacy: .public)")
  }

  func saveLoan(_ loan: Loan) async throws {
    if let original = state.loans.first(where: { $0.id == loan.id }),
      original.direction != loan.direction,
      state.transactionHistory.contains(where: {
        $0.before?.loanID == loan.id || $0.after?.loanID == loan.id
      })
    {
      throw FinanceError.invalid("Směr půjčky s účetní historií splátek nelze změnit.")
    }
    var next = state
    Self.upsert(loan, into: &next.loans)
    try await commit(next)
    logger.info("Saved loan \(loan.id.uuidString, privacy: .public)")
  }

  func deleteLoan(_ loan: Loan) async throws {
    guard !state.transactions.contains(where: { $0.loanID == loan.id }),
      !state.transactionHistory.contains(where: {
        $0.before?.loanID == loan.id || $0.after?.loanID == loan.id
      })
    else {
      throw FinanceError.invalid(
        "Půjčka má účetní historii splátek a nelze ji odstranit. Její plán můžete pozastavit v Pravidelných platbách."
      )
    }
    var next = state
    next.recurringPayments.removeAll { $0.loanID == loan.id }
    next.loans.removeAll { $0.id == loan.id }
    try await commit(next)
  }

  func saveInvestment(_ investment: InvestmentPortfolio) async throws {
    var next = state
    Self.upsert(investment, into: &next.investments)
    try await commit(next)
    logger.info("Saved investment \(investment.id.uuidString, privacy: .public)")
  }

  func deleteInvestment(_ investment: InvestmentPortfolio) async throws {
    var next = state
    next.investments.removeAll { $0.id == investment.id }
    try await commit(next)
  }

  func saveGoal(_ goal: SavingsGoal) async throws {
    var next = state
    Self.upsert(goal, into: &next.savingsGoals)
    try await commit(next)
  }

  func deleteGoal(_ goal: SavingsGoal) async throws {
    var next = state
    next.savingsGoals.removeAll { $0.id == goal.id }
    try await commit(next)
  }

  func verifyBalance(account: Account, day: Day, actual: Int64) async throws {
    let recorded = try Ledger.balance(account: account, in: state, through: day)
    guard recorded == actual else {
      throw FinanceError.invalid(
        "Evidence a banka se liší o \(Money.format(try Money.subtract(actual, recorded))). Doplňte chybějící pohyb nebo použijte dorovnání podle banky."
      )
    }
    var next = state
    next.balanceChecks.append(
      BalanceCheck(accountID: account.id, day: day, balance: actual, checkedAt: Date()))
    try await commit(next)
    statusMessage = "Zůstatek ověřen k \(displayDate(day))"
  }

  func undoTransactionChange(_ change: TransactionChange) async throws {
    var next = state
    try TransactionHistory.undo(change.id, in: &next)
    try await commit(next, recordHistory: false)
    statusMessage = "Změna transakce byla vrácena"
  }

  var latestTransactionChange: TransactionChange? {
    state.transactionHistory.last { !$0.reverted }
  }

  func transactionCategoryName(_ transaction: MoneyCore.Transaction) -> String {
    if let splits = transaction.splits, !splits.isEmpty {
      return splits.map { categoryName($0.categoryID) }.joined(separator: " + ")
    }
    return categoryName(transaction.categoryID)
  }

  func refreshReport() {
    do { report = try MonthlyReport.make(state: state, month: month) } catch {
      errorMessage = error.localizedDescription
      report = .empty
    }
  }

  func moveMonth(_ offset: Int) {
    guard
      let date = Calendar.current.date(
        byAdding: .month, value: offset, to: Day(rawValue: month + "-01").date)
    else { return }
    month = Day(date).month
    refreshReport()
  }

  func accountName(_ id: UUID) -> String {
    state.accounts.first { $0.id == id }?.name ?? "Neznámý účet"
  }
  func categoryName(_ id: UUID?) -> String {
    state.categories.first { $0.id == id }?.name ?? "Bez kategorie"
  }
  func categorySymbol(_ id: UUID?) -> String {
    state.categories.first { $0.id == id }?.symbol ?? "arrow.left.arrow.right"
  }

  func run(_ operation: @escaping @MainActor () async throws -> Void) {
    Task {
      do { try await operation() } catch { errorMessage = error.localizedDescription }
    }
  }

  func exportData(backup: Bool) async throws {
    guard let store, !busy else { return }
    let panel = NSSavePanel()
    panel.title = backup ? "Uložit úplnou zálohu" : "Exportovat transakce"
    panel.nameFieldStringValue = "MoneyApp-\(Day.today.rawValue).\(backup ? "json" : "csv")"
    panel.allowedContentTypes = backup ? [.json] : [.commaSeparatedText]
    guard await panel.begin() == .OK, let url = panel.url else { return }
    busy = true
    defer { busy = false }
    let data: Data
    if backup {
      data = try await store.exportBackup()
    } else {
      data = Data(try await store.exportCSV().utf8)
    }
    try await Task.detached { try data.write(to: url, options: .atomic) }.value
    statusMessage = backup ? "Úplná záloha byla uložena" : "Transakce byly exportovány"
  }

  func restoreData() async throws {
    guard let store, !busy else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    panel.title = "Vybrat úplnou zálohu MoneyApp"
    guard await panel.begin() == .OK, let url = panel.url else { return }
    let alert = NSAlert()
    alert.messageText = "Nahradit současná data zálohou?"
    alert.informativeText =
      "Před obnovou se uloží bezpečnostní kopie současných dat. Vybraný soubor musí být úplná záloha MoneyApp."
    alert.addButton(withTitle: "Obnovit")
    alert.addButton(withTitle: "Zrušit")
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    busy = true
    defer { busy = false }
    let data = try await Task.detached {
      let values = try url.resourceValues(forKeys: [.fileSizeKey])
      guard (values.fileSize ?? 0) <= 50_000_000 else {
        throw FinanceError.invalid("Záloha je příliš velká (maximum 50 MB).")
      }
      return try Data(contentsOf: url)
    }.value
    state = try await store.restoreBackup(data)
    refreshReport()
    statusMessage = "Data byla obnovena ze zálohy"
    logger.info("Restored complete backup")
  }

  func revealData() { NSWorkspace.shared.activateFileViewerSelecting([storageURL]) }

  private static func upsert<T: Identifiable>(_ item: T, into items: inout [T])
  where T.ID: Equatable {
    if let index = items.firstIndex(where: { $0.id == item.id }) {
      items[index] = item
    } else {
      items.append(item)
    }
  }
}
