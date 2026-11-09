import MoneyCore
import SwiftUI

struct MonthEndView: View {
  var model: AppModel
  var forecast: MonthEndForecast
  @State private var confirming: ForecastPayment?

  var body: some View {
    Surface {
      HStack {
        IconBadge(symbol: "calendar.badge.clock")
        VStack(alignment: .leading, spacing: 4) {
          Text("Do konce tohoto měsíce").font(.headline)
          Text("Odhad podle evidence a nepotvrzených pravidelných plateb").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 28) { amounts }
        VStack(alignment: .leading, spacing: 16) { amounts }
      }
      Text(
        "Odhad = peníze na aktivních běžných účtech − čekající platby z těchto účtů, včetně starších nepotvrzených úhrad. Zahrnuje odchozí splátky půjček nejvýše do zbývajícího dluhu. Nezahrnuje další nákupy, budoucí příjmy (ani příchozí splátky) a splacení kreditní karty. Rozpočty se znovu neodečítají."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if forecast.pendingCreditPayments > 0 {
        Label(
          "Navíc z kreditní karty: \(Money.format(forecast.pendingCreditPayments)) — zvýší dluh, není odečteno od hotovosti",
          systemImage: "creditcard"
        )
        .font(.callout).foregroundStyle(Palette.expense)
      }
      DisclosureGroup("Čekající platby (\(forecast.payments.count))") {
        if forecast.payments.isEmpty {
          Text("Do konce měsíce nejsou naplánované nepotvrzené platby.").foregroundStyle(.secondary)
        }
        ForEach(forecast.payments) { item in
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(item.payment.name).fontWeight(.medium)
              Text("\(displayDate(item.day)) · \(model.accountName(item.payment.accountID))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            MoneyText(amount: item.amount)
            Button("Potvrdit úhradu") { confirming = item }
              .disabled(item.day > .today || model.busy)
          }.padding(.vertical, 6)
        }
      }
      if !model.report.budgets.isEmpty {
        DisclosureGroup("Zbývá v rozpočtech") {
          ForEach(model.report.budgets) { budget in
            HStack {
              Text(budget.category)
              Spacer()
              MoneyText(amount: budget.remaining)
              if budget.spent > budget.budget.limit {
                Text("Limit překročen").font(.caption).foregroundStyle(Palette.expense)
              }
            }.padding(.vertical, 4)
          }
        }
      }
    }
    .sheet(item: $confirming) {
      PaymentConfirmation(model: model, payment: $0.payment, occurrence: $0.day)
    }
  }

  @ViewBuilder private var amounts: some View {
    amount("Aktuální peníze", forecast.cashBalance)
    amount("Čekající platby", forecast.pendingCashPayments)
    amount("Odhad po úhradách", forecast.estimatedCashBalance)
  }
  private func amount(_ title: String, _ value: Int64) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      MoneyText(amount: value).font(.title2.weight(.semibold)).foregroundStyle(
        value < 0 ? Palette.expense : Palette.accent)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct MonthComparisonView: View {
  var comparison: MonthComparison
  var body: some View {
    Surface {
      HStack {
        IconBadge(symbol: "chart.bar.xaxis")
        Text("Výdaje oproti minulému měsíci").font(.headline)
        Spacer()
      }
      HStack(spacing: 24) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Vybrané období").font(.caption).foregroundStyle(.secondary)
          MoneyText(amount: comparison.currentExpense).font(.title2.bold())
          Text("\(displayDate(comparison.currentStart)) – \(displayDate(comparison.currentEnd))")
            .font(.caption).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 5) {
          Text("Předchozí období").font(.caption).foregroundStyle(.secondary)
          MoneyText(amount: comparison.previousExpense).font(.title2.bold())
          Text("\(displayDate(comparison.previousStart)) – \(displayDate(comparison.previousEnd))")
            .font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
      }
      Label(
        "Rozdíl: \(comparison.change > 0 ? "+" : "")\(Money.format(comparison.change))",
        systemImage: comparison.change > 0
          ? "arrow.up.right" : comparison.change < 0 ? "arrow.down.right" : "equal"
      )
      .foregroundStyle(comparison.change > 0 ? Palette.expense : Palette.accent)
      Text(
        "Srovnáváme zadané výdaje. V aktuálním měsíci jen uplynulé dny; kratší předchozí měsíc končí posledním dnem. Nulová evidence nemusí znamenat nulovou útratu."
      )
      .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Rozdíly podle kategorií") {
        ForEach(comparison.categories.sorted { $0.change.magnitude > $1.change.magnitude }) {
          category in
          HStack {
            Text(category.name)
            Spacer()
            Text("\(Money.format(category.previous)) → \(Money.format(category.current))")
              .monospacedDigit()
            Text("\(category.change > 0 ? "+" : "")\(Money.format(category.change))")
              .monospacedDigit().foregroundStyle(
                category.change > 0 ? Palette.expense : Palette.accent)
          }.font(.callout).padding(.vertical, 5)
        }
      }
    }
  }
}
