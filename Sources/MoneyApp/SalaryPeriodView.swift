import Charts
import MoneyCore
import SwiftUI

struct DashboardModePicker: View {
  @Binding var mode: String

  var body: some View {
    Picker("Typ přehledu", selection: $mode) {
      Text("Výplatní období").tag("salary")
      Text("Kalendář").tag("calendar")
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .frame(width: 250)
    .accessibilityLabel("Typ přehledu")
  }
}

struct SalaryPeriodControl: View {
  let periods: [SalaryPeriod]
  @Binding var selectedID: String?

  private var index: Int {
    guard let selectedID, let index = periods.firstIndex(where: { $0.id == selectedID }) else {
      return max(periods.count - 1, 0)
    }
    return index
  }

  var body: some View {
    HStack(spacing: 10) {
      Button {
        selectedID = periods[max(index - 1, 0)].id
      } label: {
        Image(systemName: "chevron.left")
      }
      .help("Předchozí výplatní období")
      .accessibilityLabel("Předchozí výplatní období")
      .disabled(periods.isEmpty || index == 0)
      if periods.indices.contains(index) {
        Text(periodTitle(periods[index]))
          .font(.headline)
          .frame(minWidth: 190)
      } else {
        Text("Výplatní období")
          .font(.headline)
          .frame(minWidth: 190)
      }
      Button {
        selectedID = periods[min(index + 1, periods.count - 1)].id
      } label: {
        Image(systemName: "chevron.right")
      }
      .help("Následující výplatní období")
      .accessibilityLabel("Následující výplatní období")
      .disabled(periods.isEmpty || index >= periods.count - 1)
    }
    .buttonStyle(.borderless)
    .fixedSize(horizontal: true, vertical: false)
    .padding(10)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
  }

  private func periodTitle(_ period: SalaryPeriod) -> String {
    if period.start == period.end { return displayDate(period.start) }
    return "\(displayDate(period.start)) – \(displayDate(period.end))"
  }
}

struct SalaryDashboardView: View {
  var model: AppModel
  let report: SalaryPeriodReport
  @Binding var mode: String
  @Binding var selectedPeriodID: String?
  var addTransaction: () -> Void
  @AppStorage("salaryDashboardAccountID") private var selectedAccountID = ""

  private var accounts: [Account] {
    model.state.accounts.filter { $0.kind == .standard && !$0.isArchived }
  }

  private var selectedAccount: Account? {
    if let saved = accounts.first(where: { $0.id.uuidString == selectedAccountID }) {
      return saved
    }
    let salaryAccountID = model.state.transactions
      .filter { $0.kind == .income && $0.isSalary == true }
      .max { $0.day < $1.day }?.accountID
    return accounts.first { $0.id == salaryAccountID } ?? accounts.first
  }

  var body: some View {
    GeometryReader { viewport in
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          ViewThatFits(in: .horizontal) {
            HStack {
              PageHeader(
                title: "Peníze pod kontrolou.",
                subtitle: "Přehled od výplaty k výplatě.")
              Spacer()
              HStack(spacing: 12) {
                DashboardModePicker(mode: $mode)
                SalaryPeriodControl(periods: report.periods, selectedID: $selectedPeriodID)
              }
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 16) {
              PageHeader(
                title: "Peníze pod kontrolou.",
                subtitle: "Přehled od výplaty k výplatě.")
              DashboardModePicker(mode: $mode)
              SalaryPeriodControl(periods: report.periods, selectedID: $selectedPeriodID)
            }
          }
          HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
              Label("NA BĚŽNÉM ÚČTU", systemImage: "building.columns")
                .font(.caption.weight(.semibold)).tracking(1.2)
              if let account = selectedAccount {
                if accounts.count > 1 {
                  Picker(
                    "Zobrazený účet",
                    selection: Binding(
                      get: { account.id.uuidString },
                      set: { selectedAccountID = $0 }
                    )
                  ) {
                    ForEach(accounts) { account in
                      Text(account.name).tag(account.id.uuidString)
                    }
                  }
                  .labelsHidden()
                  .accessibilityLabel("Účet pro aktuální zůstatek")
                  .tint(Palette.onHero)
                } else {
                  Text(account.name).font(.callout)
                }
                if let balance = model.report.balances[account.id] {
                  MoneyText(amount: balance)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.5)
                } else {
                  Text("Zůstatek není dostupný").font(.headline)
                }
                Text("Aktuální evidovaný zůstatek k \(displayDate(.today))")
                  .font(.callout).foregroundStyle(.white.opacity(0.8))
              } else {
                Text("Žádný aktivní běžný účet").font(.headline)
              }
            }
            .foregroundStyle(Palette.onHero).padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
              LinearGradient(
                colors: [Palette.hero, Palette.heroEnd], startPoint: .topLeading,
                endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20)
            )
            .accessibilityElement(children: .contain)
            salaryMetric(
              "PŘÍJMY", value: report.income, symbol: "arrow.down.left", color: Palette.income)
            salaryMetric(
              "VÝDAJE", value: report.expense, symbol: "arrow.up.right", color: Palette.expense)
          }
          HStack(spacing: 16) {
            salaryMetric(
              "SPLÁTKY KREDITKY", value: report.creditRepayments,
              symbol: "creditcard", color: Palette.accent)
            salaryMetric(
              "VÝDAJE MIMO KREDITKU", value: report.cashExpense,
              symbol: "banknote", color: Palette.expense)
          }
          HStack(alignment: .top, spacing: 20) {
            Surface {
              HStack {
                Text("Příjmy, výdaje a splátky").font(.headline)
                Spacer()
                Text("\(displayDate(report.period.start)) – \(displayDate(report.period.end))")
                  .font(.caption).foregroundStyle(.secondary)
              }
              if report.dailyExpenses.isEmpty {
                ContentUnavailableView(
                  "Období ještě nezačalo", systemImage: "calendar",
                  description: Text("Denní výdaje zobrazujeme do dnešního dne.")
                )
                .frame(maxWidth: .infinity).frame(height: 240)
              } else {
                DailyExpensesChart(
                  points: report.dailyExpenses, income: report.spendingDetails.incomeByDay,
                  repayments: report.spendingDetails.repaymentsByDay)
              }
            }

          }
          SpendingOverview(
            model: model, categories: report.categories, total: report.expense,
            details: report.spendingDetails
          )
          .id(report.period.id)
          Surface {
            Label(
              "Výplatní období začíná označeným příjmem",
              systemImage: "calendar.badge.clock"
            )
            .font(.headline)
            Text(
              "Příjmy, výdaje a kategorie vycházejí pouze ze skutečných transakcí mezi \(displayDate(report.period.start)) a \(displayDate(report.period.end)). Splátky z běžných účtů na kreditky jsou zobrazené zvlášť, nejsou dalším výdajem. Ostatní převody nejsou zahrnuté v grafu ani v součtech příjmů a výdajů."
            )
            .font(.callout).foregroundStyle(.secondary)
            Text(
              "Na běžném účtu je dnešní evidovaný zůstatek vybraného účtu včetně počátečního stavu, všech převodů, splátek a dorovnání. Nemění se výběrem výplatního období. Ostatní částky a graf popisují pohyby za vybrané období napříč účty; jejich rozdíl není zůstatkem běžného účtu."
            )
            .font(.caption).foregroundStyle(.secondary)
            Button("Přidat transakci", action: addTransaction)
              .buttonStyle(.borderedProminent)
              .disabled(model.state.accounts.isEmpty)
          }
        }
        .padding(28).frame(maxWidth: 1200).frame(maxWidth: .infinity)
      }
    }
  }

  private func salaryMetric(_ title: String, value: Int64, symbol: String, color: Color)
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
      Text("V tomto výplatním období").font(.caption).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}
