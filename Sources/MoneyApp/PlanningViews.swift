import MoneyCore
import SwiftUI

struct BudgetsView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: Budget?
  @State private var deleting: Budget?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        HStack {
          PageHeader(title: "Rozpočty", subtitle: "Dejte svým výdajům hranice, které dávají smysl.")
          Spacer()
          MonthControl(model: model)
        }
        Button {
          adding = true
        } label: {
          Label("Nový rozpočet", systemImage: "plus")
        }.buttonStyle(.borderedProminent)
        if model.report.budgets.isEmpty {
          ContentUnavailableView(
            "Měsíc bez nastavených limitů", systemImage: "chart.bar.xaxis",
            description: Text(
              "Vyberte kategorii a určete, kolik do ní chcete tento měsíc vložit. Historické limity zůstávají beze změny."
            )
          )
          .frame(maxWidth: .infinity)
        }
        ForEach(model.report.budgets) { item in
          Surface {
            BudgetProgress(item: item)
            HStack {
              Text("\(model.month) · pouze skutečné výdaje").font(.caption).foregroundStyle(
                .secondary)
              Spacer()
              Button("Upravit") { editing = item.budget }
              Button("Odstranit", role: .destructive) { deleting = item.budget }
            }
          }
        }
      }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .sheet(isPresented: $adding) { BudgetEditor(model: model, month: model.month) }
    .sheet(item: $editing) { BudgetEditor(model: model, month: model.month, budget: $0) }
    .confirmationDialog(
      "Odstranit rozpočet pro tento měsíc?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let budget = deleting { model.run { try await model.deleteBudget(budget) } }
        deleting = nil
      }
    }
  }
}

struct RecurringView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: RecurringPayment?
  @State private var confirming: PaymentOccurrence?

  private var sortedPayments: [RecurringPaymentRow] {
    model.state.recurringPayments.map { payment in
      RecurringPaymentRow(
        payment: payment,
        amount: recurringAmountResult(for: payment, in: model.state),
        occurrence: nextOccurrenceResult(for: payment, in: model.state))
    }.sorted {
      if $0.sortAmount != $1.sortAmount { return $0.sortAmount > $1.sortAmount }
      if $0.payment.name != $1.payment.name {
        return $0.payment.name.localizedStandardCompare($1.payment.name) == .orderedAscending
      }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  private var duePayments: [UpcomingPayment] {
    model.report.upcoming.filter { $0.kind == .expense && $0.day <= .today }
      .sorted {
        if $0.amount != $1.amount { return $0.amount > $1.amount }
        if $0.day != $1.day { return $0.day < $1.day }
        return $0.id < $1.id
      }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(
          title: "Pravidelné platby",
          subtitle: "Nájem, předplatná a splátky. Bez nepříjemných překvapení."
        )
        Surface {
          HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
              Text("Plán pravidelných výdajů").font(.headline)
              Text("Splátky půjček, předplatné a ostatní pravidelné výdaje.")
                .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
              adding = true
            } label: {
              Label("Nová platba", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent).disabled(model.state.accounts.isEmpty)
          }
          HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Celkem měsíčně · včetně splátek").font(.caption).foregroundStyle(.secondary)
              Text("≈ " + Money.format(model.report.monthlyRecurringEstimate)).font(
                .title2.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 3) {
              Text("Ročně · běžné platby bez půjček").font(.caption).foregroundStyle(.secondary)
              Text(Money.format(model.report.annualRecurring)).font(.title2.weight(.semibold))
            }
          }
        }
        Text(
          "Měsíční součet zahrnuje aktivní odchozí splátky, předplatné a ostatní pravidelné platby. Roční platby jsou přepočtené na 1/12 ceny. Splátka půjčky je nejvýše do zbývajícího dluhu; příchozí a pozastavené platby se nezapočítávají. Jde o plán, nikoli zbývající úhrady tohoto měsíce. Do účtů vstoupí až potvrzená úhrada."
        )
        .font(.callout).foregroundStyle(.secondary)
        if model.state.recurringPayments.isEmpty {
          ContentUnavailableView(
            "Všechno pravidelné na jednom místě", systemImage: "repeat",
            description: Text(
              model.state.accounts.isEmpty
                ? "Nejprve vytvořte účet v sekci Účty."
                : "Přidejte nájem, telefon nebo předplatné. Každou úhradu potvrdíte až po zaplacení."
            )
          )
          .frame(maxWidth: .infinity)
        }
        if !model.state.recurringPayments.isEmpty {
          dueSection
          VStack(alignment: .leading, spacing: 4) {
            Text("Všechny pravidelné platby").font(.title2.bold())
            Text("Od nejvyšší částky za jednu platbu; roční platby jsou řazené podle celé ceny.")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        ForEach(sortedPayments) { row in
          let payment = row.payment
          let occurrenceResult = row.occurrence
          let amountResult = row.amount
          let amountAvailable: Bool = {
            if case .success = amountResult { return true }
            return false
          }()
          let linkedLoan = payment.loanID.flatMap { loanID in
            model.state.loans.first { $0.id == loanID }
          }
          Surface {
            HStack(spacing: 16) {
              IconBadge(symbol: model.categorySymbol(payment.categoryID))
              VStack(alignment: .leading, spacing: 6) {
                Text(payment.name).font(.headline)
                Text(
                  "\(payment.interval.title) · \(model.accountName(payment.accountID)) · \(model.categoryName(payment.categoryID))"
                ).font(.callout).foregroundStyle(.secondary)
                if let linkedLoan {
                  Label(
                    "Splátka: \(linkedLoan.direction.title)", systemImage: "arrow.left.arrow.right"
                  )
                  .font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer()
              switch amountResult {
              case .success(let amount):
                MoneyText(amount: amount).font(.title3.weight(.semibold))
              case .failure:
                Text("Nelze vypočítat").font(.caption).foregroundStyle(Palette.expense)
              }
            }
            HStack {
              switch occurrenceResult {
              case .success(let occurrence):
                if let occurrence {
                  Label(
                    "\(occurrence <= .today ? "K úhradě" : "Příští platba"): \(displayDate(occurrence))",
                    systemImage: "calendar"
                  )
                  .font(.callout).foregroundStyle(
                    occurrence <= .today ? Palette.expense : Color.secondary)
                } else {
                  Text(linkedLoan != nil && payment.isActive ? "Splaceno" : "Pozastaveno")
                    .foregroundStyle(.secondary)
                }
              case .failure(let error):
                Label("Nelze načíst plán", systemImage: "exclamationmark.triangle")
                  .foregroundStyle(Palette.expense)
                  .help(error.localizedDescription)
              }
              Spacer()
              Button("Upravit") { editing = payment }
              Button(payment.isActive ? "Pozastavit" : "Aktivovat") {
                var changed = payment
                changed.isActive.toggle()
                model.run { try await model.saveRecurring(changed) }
              }.disabled(model.busy)
              if case .success(let occurrence?) = occurrenceResult {
                if payment.interval == .monthly, linkedLoan?.direction != .lent {
                  skipButton(for: payment, occurrence: occurrence)
                }
                Button("Potvrdit úhradu") {
                  confirming = PaymentOccurrence(payment: payment, day: occurrence)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy || occurrence > .today || !amountAvailable)
              }
            }
            if let skipped = payment.skippedOccurrences, !skipped.isEmpty {
              DisclosureGroup("Přeskočeno bez úhrady: \(skipped.count)") {
                ForEach(skipped.sorted(by: >), id: \.rawValue) { day in
                  HStack {
                    Text(displayDate(day))
                    Spacer()
                    Button("Vrátit k úhradě") {
                      model.run {
                        try await model.restoreSkippedRecurring(payment, occurrence: day)
                      }
                    }.disabled(model.busy)
                      .accessibilityLabel("Vrátit k úhradě: \(payment.name), \(displayDate(day))")
                  }.font(.callout)
                }
              }.font(.callout)
            }
            let paid = model.state.transactions.filter { $0.recurringID == payment.id }.sorted {
              $0.day > $1.day
            }
            if !paid.isEmpty {
              DisclosureGroup("Uhrazeno: \(paid.count)") {
                ForEach(paid.prefix(12)) { transaction in
                  HStack {
                    Text(displayDate(transaction.day))
                    Spacer()
                    MoneyText(amount: transaction.amount)
                  }.font(.callout)
                }
                if paid.count > 12 { Text("Celou historii najdete v transakcích.").font(.caption) }
              }.font(.callout)
            }
          }
        }
      }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .sheet(isPresented: $adding) { RecurringEditor(model: model) }
    .sheet(item: $editing) { RecurringEditor(model: model, payment: $0) }
    .sheet(item: $confirming) {
      PaymentConfirmation(model: model, payment: $0.payment, occurrence: $0.day)
    }
  }
  private func skipButton(for payment: RecurringPayment, occurrence: Day) -> some View {
    Button("Přeskočit měsíc") {
      model.run { try await model.skipRecurring(payment, occurrence: occurrence) }
    }
    .disabled(model.busy || occurrence > .today)
    .help(
      "Přeskočí platbu k \(displayDate(occurrence)) bez úhrady. Další měsíc zůstane jedna běžná platba."
    )
    .accessibilityLabel("Přeskočit platbu: \(payment.name), \(displayDate(occurrence))")
  }

  private var dueSection: some View {
    let payments = duePayments
    return Surface {
      Label("K zaplacení (\(payments.count))", systemImage: "calendar.badge.exclamationmark")
        .font(.title2.bold())
      if payments.isEmpty {
        Label("Dnes nemáte žádné nepotvrzené platby k úhradě.", systemImage: "checkmark.circle")
          .foregroundStyle(.secondary)
      } else {
        Text(
          "Splatné dnes nebo po splatnosti. Po potvrzení se zobrazí další čekající splátka, pokud už je splatná."
        )
        .font(.caption).foregroundStyle(.secondary)
        ForEach(payments) { item in
          HStack(spacing: 16) {
            IconBadge(symbol: model.categorySymbol(item.payment.categoryID), color: Palette.expense)
            VStack(alignment: .leading, spacing: 4) {
              Text(item.payment.name).font(.headline)
              Text(
                "\(item.day < .today ? "Po splatnosti" : "Splatné dnes") · \(displayDate(item.day))"
              )
              .font(.caption).foregroundStyle(Palette.expense)
              Text(model.accountName(item.payment.accountID))
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(amount: item.amount).font(.headline)
            if item.payment.interval == .monthly {
              skipButton(for: item.payment, occurrence: item.day)
            }
            Button("Potvrdit úhradu") {
              confirming = PaymentOccurrence(payment: item.payment, day: item.day)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
            .accessibilityLabel("Potvrdit úhradu: \(item.payment.name)")
          }
          .padding(.vertical, 4)
        }
      }
    }
  }
}

private struct RecurringPaymentRow: Identifiable {
  let payment: RecurringPayment
  let amount: Result<Int64, Error>
  let occurrence: Result<Day?, Error>
  var id: UUID { payment.id }
  var sortAmount: Int64 {
    switch amount {
    case .success(let value): value
    case .failure: -1
    }
  }
}

private struct PaymentOccurrence: Identifiable {
  var payment: RecurringPayment
  var day: Day
  var id: String { payment.id.uuidString + day.rawValue }
}

private func nextOccurrenceResult(
  for payment: RecurringPayment, in state: Snapshot
) -> Result<Day?, Error> {
  Result { try Ledger.nextOccurrence(for: payment, in: state) }
}

private func recurringAmountResult(
  for payment: RecurringPayment, in state: Snapshot
) -> Result<Int64, Error> {
  Result { try Ledger.recurringAmount(for: payment, in: state) }
}

struct AccountsView: View {
  var model: AppModel
  @State private var adding = false
  @State private var editing: Account?
  @State private var reconciling: Account?
  @State private var repaying: Account?
  @State private var verifying: Account?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(title: "Moje účty", subtitle: "Zůstatky tak, jak je máte zaznamenané.")
        HStack {
          Button {
            adding = true
          } label: {
            Label("Přidat účet", systemImage: "plus")
          }.buttonStyle(.borderedProminent)
          Spacer()
          Text(
            model.state.accounts.contains(where: { $0.kind == .creditCard })
              ? "Čistý zůstatek včetně dluhů: \(Money.format(model.report.totalBalance))"
              : "Celkem \(Money.format(model.report.totalBalance))"
          ).font(.title2.weight(.semibold))
        }
        if model.state.accounts.isEmpty {
          ContentUnavailableView(
            "Vytvořte svůj první účet", systemImage: "wallet.bifold",
            description: Text("Může to být běžný účet, spoření nebo peněženka s hotovostí.")
          )
          .frame(maxWidth: .infinity)
        }
        ForEach(model.state.accounts) { account in
          if account.kind == .creditCard {
            CreditCardVisual(account: account, status: model.report.creditCards[account.id])
              .padding(.bottom, 2)
          }
          Surface {
            if account.kind != .creditCard {
              HStack(spacing: 14) {
                Image(systemName: "building.columns.fill")
                  .font(.title3)
                  .foregroundStyle(Palette.accent)
                  .frame(width: 38, height: 38)
                  .background(Palette.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                  HStack(spacing: 8) {
                    Text(account.name).font(.title3.weight(.semibold))
                    if account.isArchived {
                      Text("Archivovaný").font(.caption).foregroundStyle(.secondary)
                    }
                  }
                  Text(
                    "Výchozí stav \(Money.format(account.openingBalance)) · \(displayDate(account.openingDay))"
                  )
                  .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                MoneyText(amount: model.report.balances[account.id] ?? 0)
                  .font(.system(size: 28, weight: .semibold, design: .rounded))
              }
            }
            BalanceCheckStatus(model: model, account: account)
            HStack {
              Button("Upravit účet") { editing = account }
              Button("Ověřit zůstatek") { verifying = account }
              if account.kind == .creditCard {
                let debt = model.report.creditCards[account.id]?.debt ?? 0
                Button("Splatit celou částku") { repaying = account }
                  .buttonStyle(.borderedProminent)
                  .disabled(debt == 0 || account.isArchived)
              } else {
                Button("Dorovnat podle banky") { reconciling = account }
              }
              Spacer()
              Button(account.isArchived ? "Obnovit účet" : "Archivovat") {
                var changed = account
                changed.isArchived.toggle()
                model.run { try await model.saveAccount(changed) }
              }.disabled(model.busy)
            }
          }
        }
        Text(
          "Dorovnání napraví rozdíl ve zůstatku, ale neodhalí chybějící výdaj. Pokud víte, co jste zapomněli, přidejte raději původní transakci."
        )
        .font(.callout).foregroundStyle(.secondary)
      }.padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
    }
    .frame(maxWidth: .infinity)
    .sheet(isPresented: $adding) { AccountEditor(model: model) }
    .sheet(item: $editing) { AccountEditor(model: model, account: $0) }
    .sheet(item: $reconciling) { ReconcileEditor(model: model, account: $0) }
    .sheet(item: $verifying) { BalanceVerificationEditor(model: model, account: $0) }
    .sheet(item: $repaying) { CreditRepaymentEditor(model: model, card: $0) }
  }
}

private struct CreditCardVisual: View {
  let account: Account
  let status: CreditCardStatus?

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text("KREDITNÍ KARTA")
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .opacity(0.72)
          Text(account.name)
            .font(.title2.weight(.semibold))
          if account.isArchived {
            Text("ARCHIVOVANÝ ÚČET").font(.caption2.weight(.bold)).opacity(0.68)
          }
        }
        Spacer()
        Image(systemName: "creditcard.fill")
          .font(.title2)
          .opacity(0.85)
      }
      HStack(alignment: .bottom) {
        VStack(alignment: .leading, spacing: 3) {
          Text("AKTUÁLNÍ DLUH").font(.caption2.weight(.bold)).opacity(0.68)
          MoneyText(amount: status?.debt ?? 0)
            .font(.system(size: 25, weight: .semibold, design: .rounded))
        }
        Spacer()
        if let status {
          VStack(alignment: .trailing, spacing: 3) {
            Text("K DISPOZICI").font(.caption2.weight(.bold)).opacity(0.68)
            MoneyText(amount: status.available).font(.callout.weight(.semibold))
          }
        }
      }
      if let status {
        HStack(spacing: 12) {
          if let limit = account.creditLimit {
            Text("Limit \(Money.format(limit))")
          }
          if status.creditBalance > 0 {
            Text("Přeplatek \(Money.format(status.creditBalance))")
          }
          if status.overLimit > 0 {
            Label(
              "Překročení \(Money.format(status.overLimit))",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.yellow)
          }
        }
        .font(.caption)
        .opacity(0.82)
      }
    }
    .foregroundStyle(.white)
    .padding(24)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      LinearGradient(
        colors: [Palette.hero, Palette.heroEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      ), in: RoundedRectangle(cornerRadius: 20, style: .continuous)
    )
    .overlay(alignment: .bottomLeading) {
      Circle().fill(.white.opacity(0.08)).frame(width: 150, height: 150).offset(x: -44, y: 75)
    }
    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    .accessibilityElement(children: .combine)
  }
}
