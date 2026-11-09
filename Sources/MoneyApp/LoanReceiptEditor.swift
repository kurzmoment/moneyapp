import Foundation
import MoneyCore
import SwiftUI

struct LoanReceiptEditor: View {
  @Environment(\.dismiss) private var dismiss
  let model: AppModel
  let loan: Loan
  let installment: LoanInstallment?
  @State private var receiptID = UUID()
  @State private var accountID: UUID?
  @State private var amount: String
  @State private var paidOn = Day.today.date
  @State private var saving = false
  @State private var errorMessage: String?

  init(model: AppModel, loan: Loan, installment: LoanInstallment?) {
    self.model = model
    self.loan = loan
    self.installment = installment
    _amount = State(initialValue: installment.map { plainAmount($0.amount) } ?? "")
    let accounts = model.state.accounts.filter { $0.kind == .standard && !$0.isArchived }
    let preferred = UserDefaults.standard.string(forKey: "salaryDashboardAccountID")
    _accountID = State(
      initialValue: accounts.first { $0.id.uuidString == preferred }?.id ?? accounts.first?.id)
  }

  private var accounts: [Account] {
    model.state.accounts.filter { $0.kind == .standard && !$0.isArchived }
  }

  var body: some View {
    EditorSheet(
      title: "Přijmout splátku", saveTitle: "Připsat na účet", errorMessage: errorMessage,
      isBusy: saving || model.busy, onCancel: { dismiss() },
      onSave: { Task { @MainActor in await save() } }, canSave: accountID != nil,
      content: {
        Section("Přijaté peníze") {
          LabeledContent("Půjčka", value: loan.name)
          if accounts.isEmpty {
            Text("Nejprve vytvořte aktivní běžný účet v sekci Účty.")
          } else {
            Picker("Připsat na účet", selection: $accountID) {
              ForEach(accounts) { account in
                Text(account.name).tag(Optional(account.id))
              }
            }
          }
          TextField("Kolik vám splatil (Kč)", text: $amount)
          DatePicker(
            "Přijato", selection: $paidOn, in: ...Day.today.date, displayedComponents: .date)
          Text(
            "Částka se připíše jako příjem na vybraný účet a současně sníží zbývající dluh. Nejde o výplatu."
          )
          .font(.caption).foregroundStyle(.secondary)
          if installment != nil {
            Text(
              "Tato plánovaná splátka se nahradí skutečně přijatou částkou v účetních splátkách. Zbytek dluhu zůstane u půjčky."
            )
            .font(.caption).foregroundStyle(.secondary)
          }
        }
      })
  }

  @MainActor private func save() async {
    guard !saving, !model.busy, let accountID else { return }
    saving = true
    errorMessage = nil
    defer { saving = false }
    do {
      try await model.receiveLoanRepayment(
        loanID: loan.id, installmentID: installment?.id, receiptID: receiptID,
        accountID: accountID, amount: try Money.parse(amount), paidOn: Day(paidOn))
      dismiss()
    } catch {
      errorMessage = localizedErrorMessage(error)
    }
  }
}
