import Foundation
import MoneyCore
import SwiftUI

private var editorDateRange: PartialRangeThrough<Date> { ...Day.today.date }
typealias FinanceTransaction = MoneyCore.Transaction

func plainAmount(_ value: Int64) -> String {
  let formatted = Money.format(value)
  let withoutCurrency = formatted.hasSuffix(" Kč") ? String(formatted.dropLast(3)) : formatted
  return
    withoutCurrency
    .replacingOccurrences(of: " ", with: "")
    .replacingOccurrences(of: "\u{00A0}", with: "")
}

private func parsedAmount(_ text: String, allowNegative: Bool = false) throws -> Int64 {
  let amount = try Money.parse(text)
  if !allowNegative && amount < 0 {
    throw FinanceError.invalid("Částka musí být kladná nebo nulová.")
  }
  return amount
}

private func requiredText(_ text: String, message: String) throws -> String {
  let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { throw FinanceError.invalid(message) }
  return value
}

func localizedErrorMessage(_ error: Error) -> String {
  if let localized = error as? LocalizedError, let description = localized.errorDescription {
    return description
  }
  return error.localizedDescription
}

struct EditorSheet<Content: View>: View {
  let title: String
  let saveTitle: String
  let errorMessage: String?
  let isBusy: Bool
  let onCancel: () -> Void
  let onSave: () -> Void
  let canSave: Bool
  @ViewBuilder let content: () -> Content

  init(
    title: String, saveTitle: String, errorMessage: String?, isBusy: Bool,
    onCancel: @escaping () -> Void, onSave: @escaping () -> Void, canSave: Bool = true,
    @ViewBuilder content: @escaping () -> Content
  ) {
    self.title = title
    self.saveTitle = saveTitle
    self.errorMessage = errorMessage
    self.isBusy = isBusy
    self.onCancel = onCancel
    self.onSave = onSave
    self.canSave = canSave
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        IconBadge(symbol: "square.and.pencil")
        Text(title)
          .font(.system(size: 21, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Spacer()
      }
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface)

      Form {
        content()

        if let errorMessage, !errorMessage.isEmpty {
          Section {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.red)
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .disabled(isBusy)

      Divider()

      HStack {
        if isBusy {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Ukládání")
        }
        Spacer()
        Button("Zrušit", role: .cancel, action: onCancel)
          .keyboardShortcut(.cancelAction)
          .disabled(isBusy)
        Button(saveTitle, action: onSave)
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .disabled(isBusy || !canSave)
      }
      .controlSize(.large)
      .padding(.horizontal, 24)
      .padding(.vertical, 16)
      .background(Palette.surface)
    }
    .background(Palette.canvas)
    .frame(width: 540, height: 620)
    .navigationTitle(title)
  }
}

struct AccountEditor: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case name }
  private let model: AppModel
  private let original: Account?
  @State private var name: String
  @State private var openingBalance: String
  @State private var openingDay: Date
  @State private var isArchived: Bool
  @State private var kind: AccountKind
  @State private var creditLimit: String
  @State private var cardHasCredit: Bool
  @State private var errorMessage: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?

  init(model: AppModel, account: Account? = nil) {
    self.model = model
    self.original = account
    _name = State(initialValue: account?.name ?? "")
    let initialBalance = account?.openingBalance ?? 0
    _openingBalance = State(
      initialValue: account?.kind == .creditCard
        ? plainAmount(initialBalance).replacingOccurrences(of: "-", with: "")
        : plainAmount(initialBalance))
    _openingDay = State(initialValue: account?.openingDay.date ?? Day.today.date)
    _isArchived = State(initialValue: account?.isArchived ?? false)
    _kind = State(initialValue: account?.kind ?? .standard)
    _creditLimit = State(initialValue: account?.creditLimit.map { plainAmount($0) } ?? "")
    _cardHasCredit = State(initialValue: (account?.openingBalance ?? 0) > 0)
  }

  private var isBusy: Bool { saving || model.busy }

  var body: some View {
    EditorSheet(
      title: original == nil ? "Nový účet" : "Upravit účet",
      saveTitle: "Uložit",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } }
    ) {
      Section("Účet") {
        TextField("Název", text: $name)
          .focused($focusedField, equals: .name)
        if original?.kind != .creditCard {
          Picker("Typ účtu", selection: $kind) {
            Text(AccountKind.standard.title).tag(AccountKind.standard)
            Text(AccountKind.creditCard.title).tag(AccountKind.creditCard)
          }
        } else {
          LabeledContent("Typ účtu", value: kind.title)
        }
        if kind == .creditCard {
          TextField(cardHasCredit ? "Počáteční přeplatek" : "Počáteční dluh", text: $openingBalance)
          Toggle("Přeplatek", isOn: $cardHasCredit)
          TextField("Kreditní limit", text: $creditLimit)
            .help("Limit není vlastní peníze a každý měsíc se automaticky neresetuje.")
        } else {
          TextField("Počáteční zůstatek", text: $openingBalance)
            .help("Zadejte částku v Kč, například 12500,00")
        }
        if kind == .creditCard {
          Text(
            "Dluh zadávejte jako nezápornou částku. Při zapnutém přeplatku se uloží jako kladný zůstatek karty."
          )
          .font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          if original?.kind == .standard {
            Text(
              "Zadejte původní dluh k počátečnímu dni účtu. Úvěrový limit není zůstatek. Historické transakce zůstanou zachované."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
        DatePicker(
          "Platí od", selection: $openingDay, in: editorDateRange, displayedComponents: .date)
        Toggle("Archivovaný účet", isOn: $isArchived)
      }

      Section {
        Text(
          "Počáteční zůstatek představuje stav na začátku zvoleného dne. Transakce před tímto dnem zůstanou v historii a do výchozího stavu se znovu nezapočítají."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if original != nil {
          Text("Změna počátečního dne nebo zůstatku ovlivní výpočet zůstatku od tohoto dne.")
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear { focusedField = .name }
    .onChange(of: kind) { oldKind, newKind in
      guard oldKind == .standard, newKind == .creditCard, original?.kind == .standard else {
        return
      }
      openingBalance = ""
      cardHasCredit = false
      creditLimit = ""
    }
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      let accountName = try requiredText(name, message: "Zadejte název účtu.")
      let balance: Int64
      let limit: Int64?
      if kind == .creditCard {
        let cardAmount = try parsedAmount(openingBalance)
        balance = cardHasCredit ? cardAmount : try Money.subtract(0, cardAmount)
        let parsedLimit = try parsedAmount(creditLimit)
        guard parsedLimit > 0 else {
          throw FinanceError.invalid("Kreditní limit musí být větší než nula.")
        }
        limit = parsedLimit
      } else {
        balance = try parsedAmount(openingBalance, allowNegative: true)
        limit = nil
      }
      let day = Day(openingDay)
      guard day.isValid, day <= .today else {
        throw FinanceError.invalid("Počáteční datum nesmí být v budoucnu.")
      }
      let account = Account(
        id: original?.id ?? UUID(),
        name: accountName,
        openingBalance: balance,
        openingDay: day,
        isArchived: isArchived,
        kind: kind,
        creditLimit: limit
      )
      try await model.saveAccount(account)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

struct TransactionEditor: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case amount }
  private let model: AppModel
  private let original: FinanceTransaction?
  @State private var kind: TransactionKind
  @State private var isSalary: Bool
  @State private var amount: String
  @State private var day: Date
  @State private var accountID: UUID
  @State private var destinationAccountID: UUID?
  @State private var categoryID: UUID?
  @State private var note: String
  @State private var errorMessage: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?
  @AppStorage("lastTransactionAccount") private var lastTransactionAccount = ""
  @AppStorage("lastExpenseCategory") private var lastExpenseCategory = ""
  @State private var isSplitExpense = false
  @State private var splitRows: [SplitDraft] = []

  private static let entryKinds: [TransactionKind] = [.expense, .income, .transfer]

  init(model: AppModel, transaction: FinanceTransaction? = nil) {
    self.model = model
    self.original = transaction
    _kind = State(initialValue: transaction?.kind ?? .expense)
    _isSalary = State(initialValue: transaction?.isSalary == true)
    _amount = State(initialValue: transaction.map { plainAmount($0.amount) } ?? "")
    _day = State(initialValue: transaction?.day.date ?? Day.today.date)
    let preferredAccount = UUID(
      uuidString: UserDefaults.standard.string(forKey: "lastTransactionAccount") ?? "")
    _accountID = State(
      initialValue: transaction?.accountID ?? model.state.accounts.first(where: {
        !$0.isArchived && $0.id == preferredAccount
      })?.id ?? model.state.accounts.first(where: { !$0.isArchived })?.id ?? UUID())
    _destinationAccountID = State(initialValue: transaction?.destinationAccountID)
    let preferredCategory = UUID(
      uuidString: UserDefaults.standard.string(forKey: "lastExpenseCategory") ?? "")
    _categoryID = State(
      initialValue: transaction?.categoryID
        ?? model.state.categories.first(where: { $0.id == preferredCategory })?.id)
    _note = State(initialValue: transaction?.note ?? "")
    _isSplitExpense = State(initialValue: !(transaction?.splits?.isEmpty ?? true))
    _splitRows = State(
      initialValue: transaction?.splits?.map {
        SplitDraft(id: $0.id, categoryID: $0.categoryID, amount: plainAmount($0.amount))
      } ?? [])
  }

  private var isBusy: Bool { saving || model.busy }
  private var accounts: [Account] {
    model.state.accounts
      .filter { !$0.isArchived || $0.id == accountID || $0.id == destinationAccountID }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private var destinationAccounts: [Account] {
    accounts.filter { $0.id != accountID }
  }
  private var selectedAccount: Account? {
    model.state.accounts.first { $0.id == accountID }
  }
  private var selectedDestinationAccount: Account? {
    guard let destinationAccountID else { return nil }
    return model.state.accounts.first { $0.id == destinationAccountID }
  }
  private var isAdjustment: Bool { original?.kind == .adjustment }
  private var isRecurringTransaction: Bool { original?.recurringID != nil }
  private var isLinkedLoanRepayment: Bool { original?.loanID != nil }
  private var linkedLoan: Loan? {
    guard let loanID = original?.loanID else { return nil }
    return model.state.loans.first { $0.id == loanID }
  }
  private var historicalAccounts: [Account] {
    let transactionDay = Day(day)
    return [selectedAccount, selectedDestinationAccount]
      .compactMap { $0 }
      .filter { transactionDay < $0.openingDay }
  }
  private var historicalAccountNames: String {
    historicalAccounts.map(\.name).joined(separator: ", ")
  }
  var body: some View {
    EditorSheet(
      title: original == nil ? "Nová transakce" : "Upravit transakci",
      saveTitle: "Uložit",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } },
      content: {
        Section("Transakce") {
          if isAdjustment {
            LabeledContent("Typ", value: TransactionKind.adjustment.title)
          } else if isRecurringTransaction {
            LabeledContent("Typ", value: kind.title)
            if let linkedLoan {
              LabeledContent("Půjčka", value: "\(linkedLoan.name) · \(linkedLoan.direction.title)")
            }
          } else {
            Picker("Typ", selection: $kind) {
              ForEach(Self.entryKinds, id: \.rawValue) { value in
                Text(value.title).tag(value)
              }
            }
            if kind == .income {
              Toggle("Výplata — začíná nové období", isOn: $isSalary)
                .help("Použít den tohoto příjmu jako začátek výplatního období v přehledu.")
            }
          }
          TextField("Částka", text: $amount)
            .help(isAdjustment ? "Zadejte podepsanou částku v Kč" : "Zadejte kladnou částku v Kč")
            .focused($focusedField, equals: .amount)
          DatePicker("Datum", selection: $day, in: editorDateRange, displayedComponents: .date)
          TextField("Poznámka", text: $note, axis: .vertical)
            .lineLimit(2...5)
        }

        Section("Účty a kategorie") {
          Picker("Účet", selection: $accountID) {
            ForEach(accounts) { account in
              Text(account.name + (account.isArchived ? " (archivovaný)" : ""))
                .tag(account.id)
            }
          }

          if isAdjustment {
            EmptyView()
          } else if kind == .transfer {
            Picker("Cílový účet", selection: $destinationAccountID) {
              Text("Vyberte účet").tag(nil as UUID?)
              ForEach(destinationAccounts) { account in
                Text(account.name + (account.isArchived ? " (archivovaný)" : ""))
                  .tag(Optional(account.id))
              }
            }
          } else {
            if kind != .expense || !isSplitExpense {
              Picker("Kategorie", selection: $categoryID) {
                Text("Vyberte kategorii").tag(nil as UUID?)
                ForEach(model.state.categories) { category in
                  Text(category.name).tag(Optional(category.id))
                }
              }
            }
            if kind == .expense {
              Toggle("Rozdělit mezi kategorie", isOn: $isSplitExpense)
                .disabled(isLinkedLoanRepayment)
              if isSplitExpense {
                ForEach($splitRows) { $row in
                  HStack {
                    Picker("Kategorie", selection: $row.categoryID) {
                      Text("Vyberte kategorii").tag(nil as UUID?)
                      ForEach(model.state.categories) { category in
                        Text(category.name).tag(Optional(category.id))
                      }
                    }
                    TextField("Částka", text: $row.amount)
                      .frame(width: 110)
                    Button(role: .destructive) {
                      splitRows.removeAll { $0.id == row.id }
                    } label: {
                      Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Odebrat kategorii")
                  }
                }
                Button("Přidat kategorii", systemImage: "plus") {
                  splitRows.append(SplitDraft())
                }
                if let splitTotal, let total = parsedTotal {
                  Text("Součet rozdělení: \(Money.format(splitTotal)) z \(Money.format(total))")
                    .font(.caption).foregroundStyle(
                      splitTotal == total ? Palette.accent : Palette.expense)
                } else {
                  Text("Doplňte platné částky rozdělení i celkovou částku.")
                    .font(.caption).foregroundStyle(.secondary)
                }
              }
            }
          }
        }

        if !historicalAccounts.isEmpty {
          Section {
            Text(
              "Tato transakce je před počátečním dnem účtu \(historicalAccountNames). Zůstane v historických přehledech, ale nebude znovu měnit aktuální zůstatek."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }

        if isAdjustment {
          Section {
            Text(
              "Dorovnání má podepsanou částku a povinný důvod. Pro nové dorovnání použijte editor dorovnání účtu."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    )
    .onAppear { focusedField = .amount }
    .onChange(of: isSplitExpense) { _, enabled in
      if enabled && splitRows.isEmpty {
        splitRows = [SplitDraft(), SplitDraft()]
      }
    }
  }

  private var splitTotal: Int64? {
    let result: Result<Int64, Error> = Result {
      try Money.sum(splitRows.map { try Money.parse($0.amount) })
    }
    if case .success(let value) = result { return value }
    return nil
  }

  private var parsedTotal: Int64? {
    let result: Result<Int64, Error> = Result { try Money.parse(amount) }
    if case .success(let value) = result { return value }
    return nil
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      let transactionDay = Day(day)
      guard transactionDay.isValid, transactionDay <= .today else {
        throw FinanceError.invalid("Datum transakce nesmí být v budoucnu.")
      }
      guard let source = model.state.accounts.first(where: { $0.id == accountID }) else {
        throw FinanceError.invalid("Vyberte účet.")
      }

      if isAdjustment {
        let parsed = try parsedAmount(amount, allowNegative: true)
        guard parsed != 0 else { throw FinanceError.invalid("Dorovnání nesmí být nulové.") }
        let reason = try requiredText(note, message: "Zadejte důvod dorovnání.")
        let transaction = FinanceTransaction(
          id: original?.id ?? UUID(),
          kind: .adjustment,
          amount: parsed,
          day: transactionDay,
          accountID: source.id,
          note: reason
        )
        try await model.saveTransaction(transaction)
        dismiss()
        return
      }

      guard Self.entryKinds.contains(kind) else {
        throw FinanceError.invalid("Dorovnání upravte v editoru dorovnání účtu.")
      }
      let parsed = try parsedAmount(amount)
      guard parsed > 0 else { throw FinanceError.invalid("Zadejte částku větší než nula.") }

      let destination: UUID?
      let category: UUID?
      if kind == .transfer {
        guard let destinationAccountID else {
          throw FinanceError.invalid("Vyberte cílový účet.")
        }
        guard destinationAccountID != source.id else {
          throw FinanceError.invalid("Cílový účet musí být jiný než zdrojový účet.")
        }
        guard model.state.accounts.contains(where: { $0.id == destinationAccountID }) else {
          throw FinanceError.invalid("Vyberte platný cílový účet.")
        }
        destination = destinationAccountID
        category = nil
      } else {
        if kind == .expense && isSplitExpense {
          guard splitRows.count >= 2 else {
            throw FinanceError.invalid("Přidejte alespoň dvě kategorie.")
          }
          let splits = try splitRows.map { row -> TransactionSplit in
            guard let categoryID = row.categoryID,
              model.state.categories.contains(where: { $0.id == categoryID })
            else { throw FinanceError.invalid("Vyberte platné kategorie.") }
            let value = try parsedAmount(row.amount)
            guard value > 0 else { throw FinanceError.invalid("Částky rozdělení musí být kladné.") }
            return TransactionSplit(id: row.id, categoryID: categoryID, amount: value)
          }
          guard try Money.sum(splits.map(\.amount)) == parsed else {
            throw FinanceError.invalid("Součet rozdělení musí odpovídat částce.")
          }
          destination = nil
          category = nil
          let transaction = FinanceTransaction(
            id: original?.id ?? UUID(), kind: kind, amount: parsed, day: transactionDay,
            accountID: source.id, destinationAccountID: nil, categoryID: nil,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            recurringID: original?.recurringID, occurrenceDay: original?.occurrenceDay,
            loanID: original?.loanID, splits: splits, isSalary: nil)
          try await model.saveTransaction(transaction)
          if original == nil { lastTransactionAccount = source.id.uuidString }
          dismiss()
          return
        }
        guard let categoryID else { throw FinanceError.invalid("Vyberte kategorii.") }
        guard model.state.categories.contains(where: { $0.id == categoryID }) else {
          throw FinanceError.invalid("Vyberte platnou kategorii.")
        }
        destination = nil
        category = categoryID
      }

      let transaction = FinanceTransaction(
        id: original?.id ?? UUID(),
        kind: kind,
        amount: parsed,
        day: transactionDay,
        accountID: source.id,
        destinationAccountID: destination,
        categoryID: category,
        note: note.trimmingCharacters(in: .whitespacesAndNewlines),
        recurringID: original?.recurringID,
        occurrenceDay: original?.occurrenceDay,
        loanID: original?.loanID,
        isSalary: kind == .income ? (isRecurringTransaction ? original?.isSalary : isSalary) : nil
      )
      try await model.saveTransaction(transaction)
      if original == nil {
        lastTransactionAccount = source.id.uuidString
        if kind == .expense, let category { lastExpenseCategory = category.uuidString }
      }
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

private struct SplitDraft: Identifiable {
  var id = UUID()
  var categoryID: UUID? = nil
  var amount = ""
}

struct BudgetEditor: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case limit }
  private let model: AppModel
  private let month: String
  private let original: Budget?
  @State private var categoryID: UUID?
  @State private var limit: String
  @State private var errorMessage: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?

  init(model: AppModel, month: String, budget: Budget? = nil) {
    self.model = model
    self.month = month
    self.original = budget
    _categoryID = State(initialValue: budget?.categoryID)
    _limit = State(initialValue: plainAmount(budget?.limit ?? 0))
  }

  private var isBusy: Bool { saving || model.busy }

  var body: some View {
    EditorSheet(
      title: original == nil ? "Nový rozpočet" : "Upravit rozpočet",
      saveTitle: "Uložit",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } }
    ) {
      Section("Rozpočet") {
        LabeledContent("Měsíc", value: month)
        Picker("Kategorie", selection: $categoryID) {
          Text("Vyberte kategorii").tag(nil as UUID?)
          ForEach(model.state.categories) { category in
            Text(category.name).tag(Optional(category.id))
          }
        }
        TextField("Limit", text: $limit)
          .help("Zadejte měsíční limit v Kč")
          .focused($focusedField, equals: .limit)
      }
    }
    .onAppear { focusedField = .limit }
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      guard let categoryID, model.state.categories.contains(where: { $0.id == categoryID }) else {
        throw FinanceError.invalid("Vyberte kategorii.")
      }
      let parsedLimit = try parsedAmount(limit)
      guard month.count == 7, month.split(separator: "-").count == 2 else {
        throw FinanceError.invalid("Měsíc rozpočtu není platný.")
      }
      let budget = Budget(
        id: original?.id ?? UUID(), categoryID: categoryID, month: month, limit: parsedLimit)
      try await model.saveBudget(budget)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

struct RecurringEditor: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case name }
  private let model: AppModel
  private let original: RecurringPayment?
  @State private var name: String
  @State private var amount: String
  @State private var accountID: UUID
  @State private var categoryID: UUID?
  @State private var loanID: UUID?
  @State private var startDay: Date
  @State private var interval: RepeatInterval
  @State private var isActive: Bool
  @State private var errorMessage: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?

  init(model: AppModel, payment: RecurringPayment? = nil, loanID: UUID? = nil) {
    self.model = model
    self.original = payment
    _name = State(initialValue: payment?.name ?? "")
    _amount = State(initialValue: plainAmount(payment?.amount ?? 0))
    let selectedLoanID = payment?.loanID ?? loanID
    _accountID = State(
      initialValue: payment?.accountID
        ?? model.state.accounts.first(where: {
          !$0.isArchived && (selectedLoanID == nil || $0.kind == .standard)
        })?.id ?? UUID())
    _categoryID = State(initialValue: payment?.categoryID)
    _loanID = State(initialValue: payment?.loanID ?? loanID)
    _startDay = State(initialValue: payment?.startDay.date ?? Day.today.date)
    _interval = State(initialValue: payment?.interval ?? .monthly)
    _isActive = State(initialValue: payment?.isActive ?? true)
  }

  private var isBusy: Bool { saving || model.busy }
  private var accounts: [Account] {
    model.state.accounts
      .filter {
        if loanID != nil { return !$0.isArchived && $0.kind == .standard }
        return !$0.isArchived || $0.id == accountID
      }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private var loans: [Loan] {
    model.state.loans.sorted {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }
  }
  private var selectedLoan: Loan? {
    guard let loanID else { return nil }
    return model.state.loans.first { $0.id == loanID }
  }
  private var isLoanPlan: Bool { loanID != nil }
  private var hasRecordedOccurrences: Bool {
    guard let paymentID = original?.id else { return false }
    return !(original?.skippedOccurrences ?? []).isEmpty
      || model.state.transactions.contains {
        $0.recurringID == paymentID && $0.occurrenceDay != nil
      }
  }

  var body: some View {
    EditorSheet(
      title: original == nil ? "Nová pravidelná platba" : "Upravit pravidelnou platbu",
      saveTitle: "Uložit",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } }
    ) {
      Section("Platba") {
        TextField("Název", text: $name)
          .focused($focusedField, equals: .name)
        TextField("Částka", text: $amount)
          .help("Zadejte částku v Kč")
        Picker("Půjčka", selection: $loanID) {
          Text("Běžná platba").tag(nil as UUID?)
          ForEach(loans) { loan in
            Text("\(loan.name) · \(loan.direction.title)").tag(Optional(loan.id))
          }
        }
        .disabled(original != nil)
        if selectedLoan != nil {
          Text(
            "Plán sám nic nezaúčtuje. Po potvrzení splátky se změní dluh i vybraný účet. Opakování je měsíční."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        Picker("Účet", selection: $accountID) {
          ForEach(accounts) { account in
            Text(account.name + (account.isArchived ? " (archivovaný)" : ""))
              .tag(account.id)
          }
        }
        Picker("Kategorie", selection: $categoryID) {
          Text("Vyberte kategorii").tag(nil as UUID?)
          ForEach(model.state.categories) { category in
            Text(category.name).tag(Optional(category.id))
          }
        }
        DatePicker("První datum", selection: $startDay, displayedComponents: .date)
          .disabled(hasRecordedOccurrences)
        Picker("Opakování", selection: $interval) {
          ForEach(RepeatInterval.allCases, id: \.rawValue) { value in
            Text(value.title).tag(value)
          }
        }
        .disabled(hasRecordedOccurrences || isLoanPlan)
        Toggle("Aktivní", isOn: $isActive)
      }
      if hasRecordedOccurrences {
        Section {
          Text(
            "První datum a interval jsou uzamčené, protože už byla alespoň jedna platba potvrzena nebo přeskočena. Změna by rozpojila existující historii."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .onAppear { focusedField = .name }
    .onChange(of: loanID) { _, selectedID in
      guard original == nil, let selectedID else { return }
      interval = .monthly
      accountID =
        model.state.accounts.first(where: { !$0.isArchived && $0.kind == .standard })?.id
        ?? accountID
      guard let loan = model.state.loans.first(where: { $0.id == selectedID }) else { return }
      let result: Result<Int64, Error> = Result {
        try Ledger.remainingPrincipal(for: loan, in: model.state)
      }
      if case .success(let amount) = result {
        self.amount = plainAmount(amount)
      } else if case .failure(let error) = result {
        errorMessage = localizedErrorMessage(error)
      }
    }
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      let paymentName = try requiredText(name, message: "Zadejte název platby.")
      let parsedAmount = try parsedAmount(amount)
      guard parsedAmount > 0 else { throw FinanceError.invalid("Zadejte částku větší než nula.") }
      let savedLoanID = original?.loanID ?? loanID
      if let savedLoanID {
        guard model.state.loans.contains(where: { $0.id == savedLoanID }) else {
          throw FinanceError.invalid("Vyberte platnou půjčku.")
        }
        guard interval == .monthly else {
          throw FinanceError.invalid("Splátka půjčky může být pouze měsíční.")
        }
        guard
          model.state.accounts.contains(where: {
            $0.id == accountID && !$0.isArchived && $0.kind == .standard
          })
        else {
          throw FinanceError.invalid("Vyberte aktivní běžný účet pro splátku půjčky.")
        }
      } else {
        guard model.state.accounts.contains(where: { $0.id == accountID }) else {
          throw FinanceError.invalid("Vyberte účet.")
        }
      }
      guard let categoryID, model.state.categories.contains(where: { $0.id == categoryID }) else {
        throw FinanceError.invalid("Vyberte kategorii.")
      }
      let firstDay = Day(startDay)
      guard firstDay.isValid else { throw FinanceError.invalid("První datum není platné.") }
      let savedStartDay = hasRecordedOccurrences ? (original?.startDay ?? firstDay) : firstDay
      let savedInterval = hasRecordedOccurrences ? (original?.interval ?? interval) : interval
      let payment = RecurringPayment(
        id: original?.id ?? UUID(),
        name: paymentName,
        amount: parsedAmount,
        accountID: accountID,
        categoryID: categoryID,
        startDay: savedStartDay,
        interval: savedInterval,
        isActive: isActive,
        loanID: savedLoanID
      )
      try await model.saveRecurring(payment)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

struct PaymentConfirmation: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case amount }
  private let model: AppModel
  private let payment: RecurringPayment
  private let occurrence: Day
  @State private var paidOn: Date
  @State private var amount: String
  @State private var errorMessage: String?
  private let initialAmountError: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?

  private var linkedLoan: Loan? {
    guard let loanID = payment.loanID else { return nil }
    return model.state.loans.first { $0.id == loanID }
  }

  init(model: AppModel, payment: RecurringPayment, occurrence: Day) {
    self.model = model
    self.payment = payment
    self.occurrence = occurrence
    _paidOn = State(initialValue: Day.today.date)
    let result: Result<Int64, Error> = Result {
      try Ledger.recurringAmount(for: payment, in: model.state)
    }
    switch result {
    case .success(let value):
      _amount = State(initialValue: plainAmount(value))
      initialAmountError = nil
    case .failure(let error):
      _amount = State(initialValue: "")
      initialAmountError = localizedErrorMessage(error)
    }
    _errorMessage = State(initialValue: initialAmountError)
  }

  private var isBusy: Bool { saving || model.busy }

  var body: some View {
    EditorSheet(
      title: "Potvrdit platbu",
      saveTitle: "Potvrdit",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } },
      canSave: initialAmountError == nil
    ) {
      Section("Skutečná úhrada") {
        LabeledContent("Platba", value: payment.name)
        LabeledContent("Výskyt", value: occurrence.rawValue)
        LabeledContent("Účet", value: model.accountName(payment.accountID))
        if let linkedLoan {
          LabeledContent("Půjčka", value: "\(linkedLoan.name) · \(linkedLoan.direction.title)")
          Text(
            linkedLoan.direction == .borrowed
              ? "Úhrada sníží dluh a odečte peníze z vybraného účtu."
              : "Přijatá úhrada sníží pohledávku a zvýší zůstatek vybraného účtu."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        TextField("Skutečná částka", text: $amount)
          .focused($focusedField, equals: .amount)
        DatePicker("Uhrazeno", selection: $paidOn, in: editorDateRange, displayedComponents: .date)
      }

      Section {
        Text(
          "Při potvrzení lze upravit částku i datum skutečné úhrady. Výskyt se zapíše pouze jednou."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { focusedField = .amount }
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      if let initialAmountError {
        throw FinanceError.invalid(initialAmountError)
      }
      let actualAmount = try parsedAmount(amount)
      guard actualAmount > 0 else { throw FinanceError.invalid("Zadejte částku větší než nula.") }
      let actualDay = Day(paidOn)
      guard actualDay.isValid, actualDay <= .today else {
        throw FinanceError.invalid("Datum úhrady nesmí být v budoucnu.")
      }
      try await model.confirmRecurring(
        payment, occurrence: occurrence, paidOn: actualDay, amount: actualAmount)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

struct ReconcileEditor: View {
  @Environment(\.dismiss) private var dismiss

  private enum Field: Hashable { case target }
  private let model: AppModel
  private let account: Account
  @State private var target: String
  @State private var day: Date
  @State private var note: String
  @State private var errorMessage: String?
  @State private var saving = false
  @FocusState private var focusedField: Field?

  init(model: AppModel, account: Account) {
    self.model = model
    self.account = account
    _target = State(initialValue: "")
    _day = State(initialValue: Day.today.date)
    _note = State(initialValue: "")
  }

  private var isBusy: Bool { saving || model.busy }

  var body: some View {
    EditorSheet(
      title: "Dorovnat účet",
      saveTitle: "Dorovnat",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } }
    ) {
      Section("Účet") {
        LabeledContent("Účet", value: account.name)
        TextField("Cílový zůstatek", text: $target)
          .help("Částka může být kladná, nulová i záporná")
          .focused($focusedField, equals: .target)
        DatePicker("Datum", selection: $day, in: editorDateRange, displayedComponents: .date)
        TextField("Důvod", text: $note, axis: .vertical)
          .lineLimit(2...5)
      }

      Section {
        Text(
          "Dorovnání vytvoří samostatný pohyb a nepřepíše historii účtu. Zadejte cílový zůstatek po dorovnání."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear { focusedField = .target }
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }

    do {
      let targetAmount = try parsedAmount(target, allowNegative: true)
      let reconcileDay = Day(day)
      guard reconcileDay.isValid, reconcileDay <= .today else {
        throw FinanceError.invalid("Datum dorovnání nesmí být v budoucnu.")
      }
      let reason = try requiredText(note, message: "Zadejte důvod dorovnání.")
      try await model.reconcile(
        account: account, target: targetAmount, day: reconcileDay, note: reason)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}

struct CreditRepaymentEditor: View {
  @Environment(\.dismiss) private var dismiss

  private let model: AppModel
  private let card: Account
  @State private var sourceID: UUID?
  @State private var errorMessage: String?
  @State private var saving = false

  init(model: AppModel, card: Account) {
    self.model = model
    self.card = card
    _sourceID = State(initialValue: nil)
  }

  private var isBusy: Bool { saving || model.busy }
  private var status: CreditCardStatus? { model.report.creditCards[card.id] }
  private var sources: [Account] {
    model.state.accounts
      .filter { $0.kind == .standard && !$0.isArchived }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }
  private var debt: Int64 { status?.debt ?? 0 }

  var body: some View {
    EditorSheet(
      title: "Splatit kartu",
      saveTitle: "Zapsat splacení",
      errorMessage: errorMessage,
      isBusy: isBusy,
      onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } },
      content: {
        Section("Splacení") {
          LabeledContent("Karta", value: card.name)
          LabeledContent("Celý dluh", value: Money.format(debt))
          if sources.isEmpty {
            Label(
              "Nemáte žádný aktivní běžný účet, ze kterého lze splátku zapsat.",
              systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
          } else {
            Picker("Zdrojový účet", selection: $sourceID) {
              Text("Vyberte účet").tag(nil as UUID?)
              ForEach(sources) { source in
                Text(source.name).tag(Optional(source.id))
              }
            }
          }
        }
        Section {
          Text(
            "Zapíše převod celé částky z běžného účtu na kartu. Jde o evidenci již provedené splátky, nevytvoří druhý výdaj."
          )
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        }
      }
    )
  }

  @MainActor
  private func save() async {
    guard !isBusy else { return }
    guard debt > 0 else {
      errorMessage = "Karta nemá žádný dluh ke splacení."
      return
    }
    guard let sourceID else {
      errorMessage = "Vyberte zdrojový účet."
      return
    }
    saving = true
    errorMessage = nil
    defer { saving = false }
    do {
      try await model.repayCreditCard(card, from: sourceID)
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}
