import MoneyCore
import SwiftUI

struct SavingsGoalsView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: SavingsGoal?
  @State private var deleting: SavingsGoal?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(title: "Cíle spoření", subtitle: "Rezerva, dovolená nebo další velký plán.")
        Button("Nový cíl", systemImage: "plus") { adding = true }.buttonStyle(.borderedProminent)
        Text(
          "Odloženou částku evidujete ručně. Cíl nepřevádí peníze, nemění zůstatky a neověřuje, zda jsou peníze skutečně na účtu."
        )
        .font(.callout).foregroundStyle(.secondary)
        if model.state.savingsGoals.isEmpty {
          ContentUnavailableView(
            "Na co chcete spořit?", systemImage: "target",
            description: Text("Přidejte cíl, cílovou částku a kolik už máte odloženo.")
          )
          .frame(maxWidth: .infinity)
        }
        ForEach(model.state.savingsGoals) { goal in
          Surface {
            HStack {
              IconBadge(symbol: goal.saved >= goal.target ? "checkmark" : "target")
              Text(goal.name).font(.title3.bold())
              Spacer()
              if goal.saved >= goal.target {
                Label("Cíl splněn", systemImage: "checkmark.circle").foregroundStyle(Palette.accent)
              }
            }
            HStack {
              MoneyText(amount: goal.saved).font(.title2.bold())
              Text("z \(Money.format(goal.target))").foregroundStyle(.secondary)
              Spacer()
            }
            ProgressView(
              value: min(Double(goal.saved), Double(goal.target)), total: Double(goal.target)
            )
            .tint(Palette.accent).accessibilityLabel("Průběh cíle \(goal.name)")
            HStack {
              Button("Upravit / odložená částka") { editing = goal }
              Spacer()
              Button("Odstranit", role: .destructive) { deleting = goal }
            }
          }
        }
      }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $adding) { SavingsGoalEditor(model: model) }
    .sheet(item: $editing) { SavingsGoalEditor(model: model, goal: $0) }
    .confirmationDialog(
      "Odstranit cíl?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let goal = deleting { model.run { try await model.deleteGoal(goal) } }
        deleting = nil
      }
    } message: {
      Text("Odstraní se pouze evidence cíle, žádné peníze se nepřevádějí.")
    }
  }
}

private struct SavingsGoalEditor: View {
  var model: AppModel
  var goal: SavingsGoal?
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var target = ""
  @State private var saved = "0"
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(
        title: goal == nil ? "Nový cíl" : "Upravit cíl", subtitle: "Částky v Kč · ruční evidence")
      Form {
        TextField("Název", text: $name)
        TextField("Cílová částka", text: $target)
        TextField("Již odloženo", text: $saved)
      }
      if let error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Zrušit") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Uložit") {
          model.run {
            do {
              let value = SavingsGoal(
                id: goal?.id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                target: try Money.parse(target), saved: try Money.parse(saved))
              try await model.saveGoal(value)
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
      }
    }.padding(24).frame(width: 470).background(Palette.canvas)
      .onAppear {
        if let goal {
          name = goal.name
          target = Money.format(goal.target).replacingOccurrences(of: " Kč", with: "")
          saved = Money.format(goal.saved).replacingOccurrences(of: " Kč", with: "")
        }
      }
  }
}

struct TransactionHistoryView: View {
  var model: AppModel
  @State private var count = 50
  @State private var reverting: TransactionChange?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          title: "Historie změn",
          subtitle: "Vytvoření, úpravy a odstranění transakcí od zavedení historie.")
        Text(
          "Vrácení obnoví původní transakci a přepočítá účty i přehledy. Pokud se transakce znovu změnila, vraťte nejprve její novější změnu."
        )
        .font(.callout).foregroundStyle(.secondary)
        if model.state.transactionHistory.isEmpty {
          ContentUnavailableView(
            "Zatím žádné změny", systemImage: "clock.arrow.circlepath",
            description: Text("Další uložené změny transakcí se objeví tady.")
          )
          .frame(maxWidth: .infinity)
        }
        ForEach(Array(model.state.transactionHistory.reversed().prefix(count))) { change in
          Surface {
            HStack(alignment: .top, spacing: 12) {
              IconBadge(symbol: change.reverted ? "arrow.uturn.backward" : "clock")
              VStack(alignment: .leading, spacing: 6) {
                Text(
                  change.before == nil
                    ? "Přidání transakce"
                    : change.after == nil ? "Odstranění transakce" : "Úprava transakce"
                ).font(.headline)
                Text(change.date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                  .foregroundStyle(.secondary)
                if let before = change.before { historyLine("Před", transaction: before) }
                if let after = change.after { historyLine("Po", transaction: after) }
              }
              Spacer()
              if change.reverted {
                Label("Vráceno", systemImage: "checkmark").font(.caption).foregroundStyle(
                  .secondary)
              } else {
                Button("Vrátit změnu") { reverting = change }.disabled(model.busy)
              }
            }
          }
        }
        if count < model.state.transactionHistory.count {
          Button("Načíst další") { count += 50 }
        }
      }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    .confirmationDialog(
      "Vrátit tuto změnu?",
      isPresented: Binding(get: { reverting != nil }, set: { if !$0 { reverting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Vrátit změnu") {
        if let change = reverting { model.run { try await model.undoTransactionChange(change) } }
        reverting = nil
      }
    } message: {
      Text("Zůstatky, rozpočty a přehledy se přepočítají podle obnoveného stavu.")
    }
  }

  private func historyLine(_ label: String, transaction: MoneyCore.Transaction) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(
        "\(label): \(transaction.kind.title) · \(Money.format(transaction.amount)) · \(displayDate(transaction.day))"
      )
      Text(
        "\(model.accountName(transaction.accountID))\(transaction.destinationAccountID.map { " → " + model.accountName($0) } ?? "") · \(model.transactionCategoryName(transaction))"
      )
      if !transaction.note.isEmpty { Text(transaction.note) }
      if let splits = transaction.splits {
        ForEach(splits) { split in
          Text("\(model.categoryName(split.categoryID)): \(Money.format(split.amount))")
        }
      }
    }.font(.callout).foregroundStyle(.secondary)
  }
}

struct BalanceVerificationEditor: View {
  var model: AppModel
  var account: Account
  @Environment(\.dismiss) private var dismiss
  @State private var day = Day.today.date
  @State private var amount = ""
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      PageHeader(title: "Ověřit zůstatek", subtitle: account.name)
      Text(
        account.kind == .creditCard
          ? "Zadejte zůstatek kreditní karty: dluh jako zápornou částku, přeplatek jako kladnou."
          : "Zadejte skutečný zůstatek z banky nebo hotovosti ke konci vybraného dne."
      )
      .font(.callout).foregroundStyle(.secondary)
      Form {
        DatePicker(
          "K datu", selection: $day, in: account.openingDay.date...Day.today.date,
          displayedComponents: .date)
        TextField("Skutečný zůstatek v Kč", text: $amount)
      }
      Text("Tato kontrola nic nedorovnává. Potvrzení se uloží jen tehdy, když se částky shodují.")
        .font(.caption).foregroundStyle(.secondary)
      if let error {
        Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
      }
      HStack {
        Spacer()
        Button("Zrušit") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Ověřit") {
          model.run {
            do {
              try await model.verifyBalance(
                account: account, day: Day(day), actual: Money.parse(amount))
              dismiss()
            } catch { self.error = error.localizedDescription }
          }
        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy)
      }
    }.padding(24).frame(width: 500).background(Palette.canvas)
  }
}

struct BalanceCheckStatus: View {
  var model: AppModel
  var account: Account
  var body: some View {
    if let check = model.state.balanceChecks.filter({ $0.accountID == account.id }).max(by: {
      $0.checkedAt < $1.checkedAt
    }) {
      switch reviewStatus(check) {
      case .success(let changed):
        Label(
          changed
            ? "Po kontrole se změnila historie — ověřte znovu"
            : "Ověřeno k \(displayDate(check.day))",
          systemImage: changed ? "exclamationmark.circle" : "checkmark.seal"
        )
        .font(.caption).foregroundStyle(changed ? Palette.expense : Palette.accent)
      case .failure(let error):
        Text(error.localizedDescription).font(.caption).foregroundStyle(.red)
      }
    } else {
      Text("Zůstatek zatím nebyl ověřen").font(.caption).foregroundStyle(.secondary)
    }
  }
  private func reviewStatus(_ check: BalanceCheck) -> Result<Bool, Error> {
    Result { try TransactionHistory.checkNeedsReview(check, in: model.state) }
  }
}
