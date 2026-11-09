import Foundation
import MoneyCore
import SwiftUI

struct LoansView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: Loan?
  @State private var deleting: Loan?
  @State private var scheduling: Loan?

  private var totals: Result<LoanTotals, Error> {
    Result { try LoanTotals.make(loans: model.state.loans, transactions: model.state.transactions) }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          title: "Půjčky",
          subtitle: "Přehled peněz, které dlužíte nebo vám mají být vráceny.")
        HStack(spacing: 12) {
          Button("Nová půjčka", systemImage: "plus") { adding = true }
            .buttonStyle(.borderedProminent)
          Text("Dluhy, splatnosti a potvrzované splátky")
            .font(.callout).foregroundStyle(.secondary)
        }

        switch totals {
        case .success(let totals):
          HStack(spacing: 14) {
            WealthSummaryCard(
              title: "Dlužím", amount: totals.borrowed, symbol: "arrow.down.left",
              color: Palette.expense)
            WealthSummaryCard(
              title: "Dluží mi", amount: totals.lent, symbol: "arrow.up.right",
              color: Palette.accent)
          }
        case .failure(let error):
          WealthError(error: error)
        }

        Text(
          "Peníze, které vám někdo vrátil, zapíšete tlačítkem Přijmout splátku přímo u půjčky. Měsíční plán potvrzujte v Pravidelných platbách. Potvrzení změní dluh i vybraný účet. Starší ručně zadané úhrady zůstávají bez účetního pohybu."
        )
        .font(.callout).foregroundStyle(.secondary)

        if model.state.loans.isEmpty {
          ContentUnavailableView(
            "Zatím žádné půjčky", systemImage: "person.2",
            description: Text("Přidejte peníze půjčené od někoho nebo někomu.")
          )
          .frame(maxWidth: .infinity)
        }

        ForEach(model.state.loans.sorted { $0.startDay > $1.startDay }) { loan in
          LoanCard(
            loan: loan, model: model, onEdit: { editing = loan }, onDelete: { deleting = loan },
            onSchedule: { scheduling = loan })
        }
      }
      .padding(28)
      .frame(maxWidth: 1200)
      .frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $adding) { LoanEditor(model: model) }
    .sheet(item: $editing) { LoanEditor(model: model, loan: $0) }
    .sheet(item: $scheduling) { loan in
      RecurringEditor(
        model: model,
        payment: model.state.recurringPayments.first { $0.loanID == loan.id }, loanID: loan.id)
    }
    .confirmationDialog(
      "Odstranit půjčku?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let deleting { model.run { try await model.deleteLoan(deleting) } }
        self.deleting = nil
      }
    } message: {
      Text(
        "Odstraní se půjčka, ruční splátky a nepotvrzený pravidelný plán. Půjčku s účetní historií nelze odstranit."
      )
    }
  }

}

private struct LoanCard: View {
  let loan: Loan
  let model: AppModel
  let onEdit: () -> Void
  let onDelete: () -> Void
  let onSchedule: () -> Void
  @State private var receiving = false
  @State private var selectedInstallment: LoanInstallment?

  private var plan: RecurringPayment? {
    model.state.recurringPayments.first { $0.loanID == loan.id }
  }
  private var linkedPayments: [MoneyCore.Transaction] {
    model.state.transactions.filter { $0.loanID == loan.id }.sorted { $0.day > $1.day }
  }

  private var overdueCount: Int {
    loan.installments.filter { $0.paidDay == nil && $0.dueDay < .today }.count
  }

  var body: some View {
    switch Result(catching: { try Ledger.remainingPrincipal(for: loan, in: model.state) }) {
    case .success(let remaining):
      card(remaining: remaining)
        .sheet(isPresented: $receiving) {
          LoanReceiptEditor(model: model, loan: loan, installment: selectedInstallment)
        }
    case .failure(let error): WealthError(error: error)
    }
  }

  private func card(remaining: Int64) -> some View {
    Surface {
      HStack(alignment: .top, spacing: 14) {
        IconBadge(
          symbol: loan.direction == .borrowed ? "arrow.down.left" : "arrow.up.right",
          color: loan.direction == .borrowed ? Palette.expense : Palette.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text(loan.name).font(.title3.bold())
          Text(loan.direction.title).font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          MoneyText(amount: remaining).font(.title2.bold())
          Text("zbývá").font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 18) {
        Label("Začátek: \(displayDate(loan.startDay))", systemImage: "calendar")
        if let dueDay = loan.dueDay {
          Label("Splatnost: \(displayDate(dueDay))", systemImage: "calendar.badge.clock")
        }
        Spacer()
        Text("z \(Money.format(loan.principal))")
          .font(.callout).foregroundStyle(.secondary)
      }
      .font(.caption)
      .foregroundStyle(.secondary)

      if !loan.installments.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Plánované a starší splátky").font(.headline)
          ForEach(loan.installments.sorted { $0.dueDay < $1.dueDay }) { installment in
            HStack(spacing: 10) {
              Image(systemName: installment.paidDay == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(installment.paidDay == nil ? .secondary : Palette.accent)
              MoneyText(amount: installment.amount).fontWeight(.medium)
              Text("splatnost \(displayDate(installment.dueDay))")
                .foregroundStyle(.secondary)
              Spacer()
              if let paidDay = installment.paidDay {
                Text("uhrazeno \(displayDate(paidDay))").foregroundStyle(Palette.accent)
              } else {
                if installment.dueDay < .today {
                  Text("Po splatnosti").foregroundStyle(Palette.expense)
                }
                if loan.direction == .lent {
                  Button("Přijmout splátku") {
                    selectedInstallment = installment
                    receiving = true
                  }.disabled(model.busy || remaining == 0)
                }
              }
            }
            .font(.caption)
          }
        }
        .padding(.top, 2)
      }

      if let plan {
        Label(
          "Měsíční splátka: \(Money.format(plan.amount)) · \(plan.isActive ? "aktivní" : "pozastavená")",
          systemImage: "repeat"
        ).font(.callout)
        Text(
          "Úhrady potvrzujte v Pravidelných platbách. Poslední splátka se omezí na zbývající dluh."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !linkedPayments.isEmpty {
        DisclosureGroup("Účetní splátky: \(linkedPayments.count)") {
          ForEach(linkedPayments) { transaction in
            HStack {
              Text(displayDate(transaction.day))
              Text(model.accountName(transaction.accountID)).foregroundStyle(.secondary)
              Spacer()
              MoneyText(amount: transaction.amount)
            }.font(.caption)
          }
          Text("Úpravy a odstranění provádějte v Transakcích; dluh se přepočítá současně s účtem.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      if remaining > 0, let dueDay = loan.dueDay, dueDay < .today {
        Label("Půjčka je po celkové splatnosti", systemImage: "exclamationmark.circle.fill")
          .font(.caption.weight(.medium)).foregroundStyle(Palette.expense)
      }
      if overdueCount > 0 {
        Label(
          "Po splatnosti: \(overdueCount)", systemImage: "exclamationmark.circle.fill"
        )
        .font(.caption.weight(.medium)).foregroundStyle(Palette.expense)
      }

      HStack {
        if loan.direction == .lent {
          Button("Přijmout splátku", systemImage: "arrow.down.left") {
            selectedInstallment = nil
            receiving = true
          }.disabled(model.busy || remaining == 0)
        }
        Button("Upravit") { onEdit() }
        Button(
          plan == nil ? "Nastavit měsíční splátku" : "Upravit měsíční splátku", action: onSchedule
        )
        .disabled(model.busy || (remaining == 0 && plan == nil))
        Spacer()
        Button("Odstranit", role: .destructive) { onDelete() }
      }
    }
  }
}

private struct LoanInstallmentDraft: Identifiable {
  var id: UUID
  var amount: String
  var dueDay: Date
  var hasPaidDay: Bool
  var paidDay: Date

  init(_ installment: LoanInstallment) {
    id = installment.id
    amount = plainAmount(installment.amount)
    dueDay = installment.dueDay.date
    hasPaidDay = installment.paidDay != nil
    paidDay = installment.paidDay?.date ?? Day.today.date
  }

  init() {
    id = UUID()
    amount = ""
    dueDay = Day.today.date
    hasPaidDay = false
    paidDay = Day.today.date
  }
}

private struct LoanEditor: View {
  var model: AppModel
  var loan: Loan?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var direction: LoanDirection
  @State private var principal: String
  @State private var startDay: Date
  @State private var hasDueDay: Bool
  @State private var dueDay: Date
  @State private var installments: [LoanInstallmentDraft]
  @State private var errorMessage: String?
  @State private var saving = false

  init(model: AppModel, loan: Loan? = nil) {
    self.model = model
    self.loan = loan
    _name = State(initialValue: loan?.name ?? "")
    _direction = State(initialValue: loan?.direction ?? .borrowed)
    _principal = State(initialValue: plainAmount(loan?.principal ?? 0))
    _startDay = State(initialValue: loan?.startDay.date ?? Day.today.date)
    _hasDueDay = State(initialValue: loan?.dueDay != nil)
    _dueDay = State(initialValue: loan?.dueDay?.date ?? Day.today.date)
    _installments = State(initialValue: loan?.installments.map(LoanInstallmentDraft.init) ?? [])
  }

  var body: some View {
    EditorSheet(
      title: loan == nil ? "Nová půjčka" : "Upravit půjčku", saveTitle: "Uložit",
      errorMessage: errorMessage, isBusy: saving || model.busy,
      onCancel: { dismiss() }, onSave: { Task { @MainActor in await save() } },
      content: {
        Section("Půjčka") {
          TextField("Název nebo osoba", text: $name)
          Picker("Směr", selection: $direction) {
            ForEach(LoanDirection.allCases, id: \.self) { Text($0.title).tag($0) }
          }
          TextField("Výchozí dluh", text: $principal)
            .help("Částka v Kč, například 25000 nebo 25000,50")
          DatePicker(
            "Od data", selection: $startDay, in: ...Day.today.date, displayedComponents: .date)
          Toggle("Má celkovou splatnost", isOn: $hasDueDay)
          if hasDueDay {
            DatePicker("Celková splatnost", selection: $dueDay, displayedComponents: .date)
          }
        }
        Section {
          ForEach($installments) { $draft in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Splátka").font(.headline)
                Spacer()
                Button("Odstranit", role: .destructive) {
                  installments.removeAll { $0.id == draft.id }
                }
                .buttonStyle(.borderless)
              }
              TextField("Částka", text: $draft.amount)
              DatePicker("Splatnost", selection: $draft.dueDay, displayedComponents: .date)
              Toggle("Starší úhrada bez pohybu na účtu", isOn: $draft.hasPaidDay)
              if draft.hasPaidDay {
                DatePicker(
                  "Skutečně uhrazeno", selection: $draft.paidDay, in: ...Day.today.date,
                  displayedComponents: .date)
              }
            }
            .padding(.vertical, 4)
          }
          Button("Přidat plánovanou splátku", systemImage: "plus") {
            installments.append(LoanInstallmentDraft())
          }
        } header: {
          Text("Ruční evidence splátek")
        } footer: {
          Text(
            "Přijetí peněz na účet zapište tlačítkem Přijmout splátku u uložené půjčky. Označení starší úhrady zde nemění účet. Nepotvrzené ruční splátky před zapnutím plánu odstraňte."
          )
        }
      })
  }

  private func save() async {
    saving = true
    defer { saving = false }
    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else { throw FinanceError.invalid("Název půjčky je prázdný.") }
      let principalValue = try Money.parse(principal)
      guard principalValue > 0 else { throw FinanceError.invalid("Výchozí dluh musí být kladný.") }
      let mapped = try installments.map { draft in
        let amount = try Money.parse(draft.amount)
        guard amount > 0 else { throw FinanceError.invalid("Částka splátky musí být kladná.") }
        return LoanInstallment(
          id: draft.id, amount: amount, dueDay: Day(draft.dueDay),
          paidDay: draft.hasPaidDay ? Day(draft.paidDay) : nil)
      }
      let loanValue = Loan(
        id: loan?.id ?? UUID(), name: trimmedName, direction: direction, principal: principalValue,
        startDay: Day(startDay), dueDay: hasDueDay ? Day(dueDay) : nil, installments: mapped)
      try await model.saveLoan(loanValue)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

struct InvestmentsView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: InvestmentPortfolio?
  @State private var deleting: InvestmentPortfolio?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          title: "Investice",
          subtitle: "Ručně evidovaná hodnota portfolií a pohyby v Kč.")
        HStack(spacing: 12) {
          Button("Nové portfolio", systemImage: "plus") { adding = true }
            .buttonStyle(.borderedProminent)
          Text("Ruční evidence • bez bankovního napojení")
            .font(.callout).foregroundStyle(.secondary)
        }
        Text(
          "Přidejte například XTB nebo Coinbase. Výnos je rozdíl k datu ocenění: hodnota + výběry − vklady. Nejde o roční procentní výnos a zápis nemění účty ani transakce."
        )
        .font(.callout).foregroundStyle(.secondary)

        if model.state.investments.isEmpty {
          ContentUnavailableView(
            "Zatím žádné portfolio", systemImage: "chart.line.uptrend.xyaxis",
            description: Text("Založte portfolio a doplňte první historický vklad.")
          )
          .frame(maxWidth: .infinity)
        }
        ForEach(
          model.state.investments.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
          }
        ) { portfolio in
          InvestmentCard(
            portfolio: portfolio, onEdit: { editing = portfolio },
            onDelete: { deleting = portfolio })
        }
      }
      .padding(28)
      .frame(maxWidth: 1200)
      .frame(maxWidth: .infinity)
    }
    .sheet(isPresented: $adding) { InvestmentEditor(model: model) }
    .sheet(item: $editing) { InvestmentEditor(model: model, portfolio: $0) }
    .confirmationDialog(
      "Odstranit portfolio?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let deleting { model.run { try await model.deleteInvestment(deleting) } }
        self.deleting = nil
      }
    } message: {
      Text("Odstraní se portfolio, jeho vklady, výběry a ocenění. Účty zůstanou beze změny.")
    }
  }
}

private struct InvestmentCard: View {
  let portfolio: InvestmentPortfolio
  let onEdit: () -> Void
  let onDelete: () -> Void

  var body: some View {
    switch Result(catching: { try InvestmentSummary.make(portfolio: portfolio) }) {
    case .success(let summary): card(summary: summary)
    case .failure(let error): WealthError(error: error)
    }
  }

  private func card(summary: InvestmentSummary) -> some View {
    Surface {
      HStack(alignment: .top, spacing: 14) {
        IconBadge(symbol: "chart.line.uptrend.xyaxis", color: Palette.accent)
        VStack(alignment: .leading, spacing: 5) {
          Text(portfolio.name).font(.title3.bold())
          Text("Ocenění k \(displayDate(portfolio.valuedOn))")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 4) {
          MoneyText(amount: portfolio.currentValue).font(.title2.bold())
          Text("poslední zadaná hodnota").font(.caption).foregroundStyle(.secondary)
        }
      }

      HStack(spacing: 20) {
        WealthMetric(title: "Vklady k ocenění", amount: summary.deposits)
        WealthMetric(title: "Výběry k ocenění", amount: summary.withdrawals)
        if summary.hasRecordedDeposits {
          WealthMetric(
            title: "Rozdíl k ocenění", amount: summary.difference,
            tint: summary.difference >= 0 ? Palette.accent : Palette.expense)
        }
      }

      if !summary.hasRecordedDeposits {
        Text("Doplňte historické vklady a výběry pro smysluplný výpočet rozdílu.")
          .font(.caption).foregroundStyle(.secondary)
      }
      if summary.hasLaterMovements {
        Text(
          "Máte novější pohyby než ocenění. Aktualizujte hodnotu a datum ocenění; do zobrazeného rozdílu zatím nevstupují."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      if !portfolio.entries.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          Text("Pohyby").font(.headline)
          ForEach(portfolio.entries.sorted { $0.day > $1.day }.prefix(5)) { entry in
            HStack {
              Image(systemName: entry.kind == .deposit ? "arrow.down.circle" : "arrow.up.circle")
                .foregroundStyle(entry.kind == .deposit ? Palette.accent : Palette.expense)
              Text(entry.kind.title)
              Text(displayDate(entry.day)).foregroundStyle(.secondary)
              Spacer()
              MoneyText(amount: entry.amount)
            }
            .font(.caption)
          }
          if portfolio.entries.count > 5 {
            Text("Další pohyby jsou v editoru.").font(.caption).foregroundStyle(.secondary)
          }
        }
      }

      HStack {
        Button("Upravit") { onEdit() }
        Spacer()
        Button("Odstranit", role: .destructive) { onDelete() }
      }
    }
  }
}

private struct WealthMetric: View {
  var title: String
  var amount: Int64
  var tint: Color = .primary
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      MoneyText(amount: amount).font(.callout.weight(.semibold)).foregroundStyle(tint)
    }
  }
}

private struct WealthSummaryCard: View {
  var title: String
  var amount: Int64
  var symbol: String
  var color: Color
  var body: some View {
    Surface {
      HStack(spacing: 12) {
        IconBadge(symbol: symbol, color: color)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.callout).foregroundStyle(.secondary)
          MoneyText(amount: amount).font(.title2.bold())
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private struct InvestmentEntryDraft: Identifiable {
  var id: UUID
  var kind: InvestmentEntryKind
  var amount: String
  var day: Date

  init(_ entry: InvestmentEntry) {
    id = entry.id
    kind = entry.kind
    amount = plainAmount(entry.amount)
    day = entry.day.date
  }

  init() {
    id = UUID()
    kind = .deposit
    amount = ""
    day = Day.today.date
  }
}

private struct InvestmentEditor: View {
  var model: AppModel
  var portfolio: InvestmentPortfolio?
  @Environment(\.dismiss) private var dismiss
  @State private var name: String
  @State private var currentValue: String
  @State private var valuedOn: Date
  @State private var entries: [InvestmentEntryDraft]
  @State private var errorMessage: String?
  @State private var saving = false

  init(model: AppModel, portfolio: InvestmentPortfolio? = nil) {
    self.model = model
    self.portfolio = portfolio
    _name = State(initialValue: portfolio?.name ?? "")
    _currentValue = State(initialValue: plainAmount(portfolio?.currentValue ?? 0))
    _valuedOn = State(initialValue: portfolio?.valuedOn.date ?? Day.today.date)
    _entries = State(initialValue: portfolio?.entries.map(InvestmentEntryDraft.init) ?? [])
  }

  var body: some View {
    EditorSheet(
      title: portfolio == nil ? "Nové portfolio" : "Upravit portfolio", saveTitle: "Uložit",
      errorMessage: errorMessage, isBusy: saving || model.busy,
      onCancel: { dismiss() }, onSave: { Task { @MainActor in await save() } },
      content: {
        Section("Portfolio") {
          TextField("Název platformy", text: $name)
            .help("Například XTB nebo Coinbase")
          TextField("Současná hodnota", text: $currentValue)
          DatePicker(
            "Oceněno k", selection: $valuedOn, in: ...Day.today.date, displayedComponents: .date)
          Text("Hodnota i pohyby jsou v Kč. Ocenění se vztahuje k uvedenému datu.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Section {
          ForEach($entries) { $entry in
            VStack(alignment: .leading, spacing: 8) {
              HStack {
                Text("Pohyb").font(.headline)
                Spacer()
                Button("Odstranit", role: .destructive) {
                  entries.removeAll { $0.id == entry.id }
                }
                .buttonStyle(.borderless)
              }
              Picker("Typ", selection: $entry.kind) {
                ForEach(InvestmentEntryKind.allCases, id: \.self) { Text($0.title).tag($0) }
              }
              TextField("Částka", text: $entry.amount)
              DatePicker("Datum", selection: $entry.day, displayedComponents: .date)
            }
            .padding(.vertical, 4)
          }
          Button("Přidat vklad nebo výběr", systemImage: "plus") {
            entries.append(InvestmentEntryDraft())
          }
        } header: {
          Text("Vklady a výběry")
        } footer: {
          Text(
            "Doplňte i historické vklady a výběry. Pro výpočet rozdílu se započítají jen pohyby k datu ocenění nebo dříve. Cizí měny převeďte do Kč ručně; aplikace kurzy nenačítá."
          )
        }
      })
  }

  private func save() async {
    saving = true
    defer { saving = false }
    do {
      let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmedName.isEmpty else { throw FinanceError.invalid("Název portfolia je prázdný.") }
      let currentValueAmount = try Money.parse(currentValue)
      guard currentValueAmount >= 0 else {
        throw FinanceError.invalid("Současná hodnota nesmí být záporná.")
      }
      let mapped = try entries.map { entry in
        let amount = try Money.parse(entry.amount)
        guard amount > 0 else { throw FinanceError.invalid("Částka pohybu musí být kladná.") }
        return InvestmentEntry(id: entry.id, kind: entry.kind, amount: amount, day: Day(entry.day))
      }
      let portfolio = InvestmentPortfolio(
        id: portfolio?.id ?? UUID(), name: trimmedName, entries: mapped,
        currentValue: currentValueAmount, valuedOn: Day(valuedOn))
      try await model.saveInvestment(portfolio)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

private struct WealthError: View {
  let error: Error
  var body: some View {
    Label(error.localizedDescription, systemImage: "exclamationmark.triangle")
      .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
  }
}
