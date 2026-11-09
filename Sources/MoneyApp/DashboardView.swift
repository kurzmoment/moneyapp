import Charts
import MoneyCore
import SwiftUI

struct DashboardView: View {
  var model: AppModel
  var addTransaction: () -> Void
  var addAccount: () -> Void
  @AppStorage("chartPeriod") private var chartPeriod = "days"
  @AppStorage("dashboardMode") private var dashboardMode = "salary"
  @State private var confirming: UpcomingPayment?
  @State private var selectedSalaryPeriodID: String?

  var body: some View {
    Group {
      if dashboardMode == "salary", let result = salaryReportResult {
        switch result {
        case .success(let report):
          SalaryDashboardView(
            model: model, report: report, mode: $dashboardMode,
            selectedPeriodID: $selectedSalaryPeriodID, addTransaction: addTransaction)
        case .failure(let error):
          calendarBody(
            salaryHint:
              "Výplatní přehled se nepodařilo načíst: \(error.localizedDescription) Kalendářní přehled zůstává dostupný."
          )
        }
      } else {
        calendarBody(
          salaryHint:
            dashboardMode == "salary"
            ? "Dosavadní data zůstávají v kalendářním přehledu. Až dorazí další výplata, přidejte příjem a zapněte „Výplata — začíná nové období“."
            : nil)
      }
    }
    .sheet(item: $confirming) {
      PaymentConfirmation(model: model, payment: $0.payment, occurrence: $0.day)
    }
  }

  private var salaryReportResult: Result<SalaryPeriodReport, Error>? {
    let periods = SalaryPeriodReport.availablePeriods(in: model.state)
    guard let latest = periods.last else { return nil }
    let selected =
      selectedSalaryPeriodID.flatMap { id in periods.first { $0.id == id } }
      ?? latest
    return Result { try SalaryPeriodReport.make(state: model.state, period: selected) }
  }

  @ViewBuilder
  private func calendarBody(salaryHint: String?) -> some View {
    GeometryReader { viewport in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ViewThatFits(in: .horizontal) {
            HStack {
              PageHeader(
                title: "Peníze pod kontrolou.",
                subtitle: "Jasný pohled na to, kam vaše peníze míří.")
              Spacer()
              HStack(spacing: 12) {
                DashboardModePicker(mode: $dashboardMode)
                MonthControl(model: model)
              }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 16) {
              PageHeader(
                title: "Peníze pod kontrolou.",
                subtitle: "Jasný pohled na to, kam vaše peníze míří.")
              DashboardModePicker(mode: $dashboardMode)
              MonthControl(model: model)
            }
          }
          if let salaryHint {
            Surface {
              Label("Výplatní přehled zatím není k dispozici", systemImage: "calendar.badge.clock")
                .font(.headline)
              Text(salaryHint).font(.callout).foregroundStyle(.secondary)
            }
          }
          if model.state.accounts.isEmpty {
            Surface {
              HStack(alignment: .top, spacing: 20) {
                Image(systemName: "wallet.bifold").font(.system(size: 42)).foregroundStyle(
                  Palette.accent)
                VStack(alignment: .leading, spacing: 12) {
                  Text("Začněte svým prvním účtem").font(.title2.bold())
                  Text(
                    "Pojmenujte účet, zadejte počáteční zůstatek a pak přidávejte příjmy a výdaje. Všechna data zůstávají na vašem Macu."
                  )
                  .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                  Button("Přidat první účet", action: addAccount).buttonStyle(.borderedProminent)
                }
              }.padding(.vertical, 18)
            }
          }
          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
              Label("BILANCE MĚSÍCE", systemImage: "chart.line.uptrend.xyaxis")
                .font(.caption.weight(.semibold)).tracking(1.2)
              MoneyText(amount: model.report.difference)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.5)
              Text("Příjmy minus výdaje").font(.callout).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(Palette.onHero).padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              LinearGradient(
                colors: [Palette.hero, Palette.heroEnd], startPoint: .topLeading,
                endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20)
            )
            .accessibilityElement(children: .combine)
            metric(
              "PŘÍJMY", value: model.report.income, symbol: "arrow.down.left",
              color: Palette.income,
              caption: "Za vybraný měsíc")
            metric(
              "VÝDAJE", value: model.report.expense, symbol: "arrow.up.right",
              color: Palette.expense,
              caption: "Bez převodů a dorovnání")
          }
          HStack(alignment: .top, spacing: 20) {
            Surface {
              HStack {
                Text("Vývoj financí").font(.headline)
                Spacer()
                Text(chartPeriod == "days" ? "Vybraný měsíc • Kč" : "6 měsíců • Kč").font(.caption)
                  .foregroundStyle(.secondary)
              }
              Picker("Období grafu", selection: $chartPeriod) {
                Text("Dny").tag("days")
                Text("Měsíce").tag("months")
              }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
              if chartPeriod == "days" {
                DailyExpensesChart(
                  points: model.report.dailyExpenses,
                  income: model.report.spendingDetails?.incomeByDay ?? [:],
                  repayments: model.report.spendingDetails?.repaymentsByDay ?? [:])
              } else if model.state.transactions.isEmpty {
                ContentUnavailableView(
                  "Váš příběh teprve začíná", systemImage: "chart.bar",
                  description: Text("Po přidání transakcí tady uvidíte vývoj příjmů a výdajů.")
                )
                .frame(maxWidth: .infinity).frame(height: 240)
              } else {
                Chart(model.report.trend) { point in
                  BarMark(
                    x: .value("Měsíc", monthLabel(point.id)),
                    y: .value("Kč", Double(point.income) / 100)
                  )
                  .cornerRadius(5)
                  .foregroundStyle(by: .value("Druh", "Příjmy")).position(
                    by: .value("Druh", "Příjmy")
                  )
                  .accessibilityLabel("\(point.id), příjmy").accessibilityValue(
                    Money.format(point.income))
                  BarMark(
                    x: .value("Měsíc", monthLabel(point.id)),
                    y: .value("Kč", Double(point.expense) / 100)
                  )
                  .cornerRadius(5)
                  .foregroundStyle(by: .value("Druh", "Výdaje")).position(
                    by: .value("Druh", "Výdaje")
                  )
                  .accessibilityLabel("\(point.id), výdaje").accessibilityValue(
                    Money.format(point.expense))
                }
                .chartForegroundStyleScale(["Příjmy": Palette.accent, "Výdaje": Palette.expense])
                .chartLegend(position: .bottom, alignment: .leading, spacing: 18)
                .chartYAxis {
                  AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    AxisValueLabel()
                  }
                }
                .chartXAxis { AxisMarks { AxisValueLabel() } }
                .frame(maxWidth: .infinity).frame(height: 240)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Vývoj příjmů a výdajů za šest měsíců")
                .accessibilityValue(
                  model.report.trend.map {
                    "\($0.id): příjmy \(Money.format($0.income)), výdaje \(Money.format($0.expense))"
                  }.joined(separator: ". "))
                DisclosureGroup("Přesné hodnoty") {
                  ForEach(model.report.trend) { item in
                    HStack {
                      Text(item.id)
                      Spacer()
                      Text(
                        "Příjmy \(Money.format(item.income)) · Výdaje \(Money.format(item.expense))"
                      )
                    }.font(.caption)
                  }
                }.font(.caption)
              }
            }

          }
          if let details = model.report.spendingDetails {
            SpendingOverview(
              model: model, categories: model.report.categories, total: model.report.expense,
              details: details
            )
            .id(model.month)
          }
          if let forecast = model.report.monthEndForecast {
            MonthEndView(model: model, forecast: forecast)
          }
          if let comparison = model.report.comparison {
            MonthComparisonView(comparison: comparison)
          }
          HStack(alignment: .top, spacing: 20) {
            Surface {
              Text("Prostor pro úspory").font(.headline)
              if model.report.insights.isEmpty {
                Label("Zatím málo podkladů", systemImage: "leaf").foregroundStyle(Palette.accent)
                Text(
                  "Nastavte rozpočty a pravidelné platby. Upozornění vycházejí pouze z vašich dat, nikoli z odhadů vašich návyků."
                ).font(.callout).foregroundStyle(.secondary)
              } else {
                ForEach(model.report.insights.prefix(4)) { insight in
                  HStack(alignment: .top, spacing: 12) {
                    IconBadge(symbol: insight.symbol)
                    VStack(alignment: .leading, spacing: 5) {
                      Text(insight.title).font(.callout.bold())
                      Text(insight.detail).font(.callout).foregroundStyle(.secondary).fixedSize(
                        horizontal: false, vertical: true)
                    }
                  }
                }
              }
            }
            Surface {
              Text("Moje účty").font(.headline)
              Text(
                model.report.creditCards.isEmpty
                  ? "Aktuální evidovaný zůstatek" : "Čistý zůstatek včetně dluhů"
              ).font(.caption).foregroundStyle(.secondary)
              MoneyText(amount: model.report.totalBalance).font(
                .system(size: 26, weight: .semibold, design: .rounded))
              ForEach(model.state.accounts.filter { !$0.isArchived }) { account in
                VStack(alignment: .leading, spacing: 4) {
                  HStack {
                    Text(account.name).foregroundStyle(.secondary)
                    Spacer()
                    if let card = model.report.creditCards[account.id] {
                      Text("Dluh \(Money.format(card.debt))")
                    } else {
                      MoneyText(amount: model.report.balances[account.id] ?? 0)
                    }
                  }
                  if let card = model.report.creditCards[account.id] {
                    Text("Dostupný úvěr \(Money.format(card.available))").font(.caption)
                      .foregroundStyle(.secondary)
                  }
                }.font(.callout)
              }
              Text("Shoda s bankou závisí na úplnosti ruční evidence.").font(.caption)
                .foregroundStyle(.secondary)
            }.frame(width: min(360, max(290, (min(viewport.size.width, 1200) - 56) * 0.32)))
          }
          if !model.report.budgets.isEmpty {
            Surface {
              Text("Rozpočty v tomto měsíci").font(.headline)
              ForEach(model.report.budgets) { item in BudgetProgress(item: item) }
            }
          }
          if !model.report.upcoming.isEmpty {
            Surface {
              Text("Nejbližší pravidelné platby").font(.headline)
              ForEach(model.report.upcoming.prefix(4)) { item in
                HStack(spacing: 16) {
                  Image(systemName: "calendar").foregroundStyle(Palette.accent)
                  VStack(alignment: .leading, spacing: 4) {
                    Text(item.payment.name).fontWeight(.medium)
                    if item.kind == .income {
                      Text("Příchozí splátka").font(.caption).foregroundStyle(Palette.income)
                    }
                    Text(
                      "\(item.day <= .today ? "K úhradě" : "Splatnost") · \(displayDate(item.day))"
                    ).font(.caption).foregroundStyle(.secondary)
                  }
                  Spacer()
                  MoneyText(amount: item.amount)
                  Button("Potvrdit úhradu") { confirming = item }.disabled(
                    item.day > .today || model.busy)
                }
              }
            }
          }
        }.padding(28).frame(maxWidth: 1200)
          .frame(maxWidth: .infinity)
      }
    }
  }

  private func metric(_ title: String, value: Int64, symbol: String, color: Color, caption: String)
    -> some View
  {
    Surface {
      HStack {
        Text(title).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary)
        Spacer()
        IconBadge(symbol: symbol, color: color)
      }
      MoneyText(amount: value).font(.system(size: 26, weight: .semibold, design: .rounded))
        .minimumScaleFactor(0.7).lineLimit(1)
      Text(caption).font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }

  private func monthLabel(_ month: String) -> String {
    Day(rawValue: month + "-01").date.formatted(
      .dateTime.month(.abbreviated).locale(Locale(identifier: "cs_CZ")))
  }
}

struct BudgetProgress: View {
  var item: BudgetStatus
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Label(item.category, systemImage: "chart.bar.fill").font(.headline)
        Spacer()
        Text("\(Money.format(item.spent)) / \(Money.format(item.budget.limit))").monospacedDigit()
      }
      ProgressView(
        value: min(Double(item.spent), Double(item.budget.limit)),
        total: max(Double(item.budget.limit), 1)
      )
      .tint(item.spent > item.budget.limit ? Palette.expense : Palette.accent)
      .accessibilityLabel("Čerpání rozpočtu \(item.category)")
      if item.spent > item.budget.limit {
        Label("Limit překročen", systemImage: "exclamationmark.circle").font(.caption)
          .foregroundStyle(Palette.expense)
      }
    }
  }
}
