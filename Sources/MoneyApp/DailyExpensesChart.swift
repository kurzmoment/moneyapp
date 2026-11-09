import Charts
import MoneyCore
import SwiftUI

struct DailyExpensesChart: View {
  let points: [DayExpense]
  var income: [Day: Int64] = [:]
  var repayments: [Day: Int64] = [:]
  @State private var selectedIndex: Int?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 24) {
        legend("Příjmy", color: Palette.income)
        legend("Výdaje", color: Palette.expense)
        legend("Splátky kreditky", color: .indigo)
        Spacer()
        Text("Kč / den").font(.caption).foregroundStyle(.secondary)
      }
      Chart {
        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
          bars(index: index, day: point.day, expense: point.amount)
        }
        if let selectedIndex, points.indices.contains(selectedIndex - 1) {
          RuleMark(x: .value("Den", selectedIndex))
            .foregroundStyle(.secondary.opacity(0.45))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .annotation(
              position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
            ) {
              tooltip(points[selectedIndex - 1])
            }
        }
      }
      .chartForegroundStyleScale([
        "Příjmy": Palette.income, "Výdaje": Palette.expense, "Splátky kreditky": Color.indigo,
      ])
      .chartLegend(.hidden)
      .chartXScale(domain: 0.5...max(1.5, Double(points.count) + 0.5))
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 7)) { value in
          AxisValueLabel {
            if let number = value.as(Int.self), points.indices.contains(number - 1) {
              Text(
                points[number - 1].day.date.formatted(
                  .dateTime.day().month(.twoDigits).locale(Locale(identifier: "cs_CZ"))))
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) {
          AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 5]))
          AxisValueLabel()
        }
      }
      .chartOverlay { proxy in
        GeometryReader { geometry in
          Rectangle().fill(.clear).contentShape(Rectangle())
            .onContinuousHover { phase in
              switch phase {
              case .active(let location): select(location, proxy: proxy, geometry: geometry)
              case .ended: selectedIndex = nil
              }
            }
            .onTapGesture { location in select(location, proxy: proxy, geometry: geometry) }
        }
      }
      .frame(height: 310)
      Text("Najeďte na den pro přesné částky. Splátky kreditky nejsou dalším výdajem.")
        .font(.caption).foregroundStyle(.secondary)
      DisclosureGroup("Přesné denní částky") {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
          GridRow {
            Text("Datum")
            Text("Příjmy")
            Text("Výdaje")
            Text("Splátky kreditky")
          }.fontWeight(.semibold)
          ForEach(points) { point in
            GridRow {
              Text(displayDate(point.day))
              MoneyText(amount: income[point.day] ?? 0)
              MoneyText(amount: point.amount)
              MoneyText(amount: repayments[point.day] ?? 0)
            }
          }
        }.font(.callout).padding(.top, 12)
      }.font(.caption)
    }
    .onChange(of: points.first?.id) { selectedIndex = nil }
  }

  @ChartContentBuilder
  private func bars(index: Int, day: Day, expense: Int64) -> some ChartContent {
    bar(index: index, day: day, title: "Příjmy", amount: income[day] ?? 0, offset: -0.24)
    bar(index: index, day: day, title: "Výdaje", amount: expense, offset: 0)
    bar(
      index: index, day: day, title: "Splátky kreditky", amount: repayments[day] ?? 0, offset: 0.24)
  }

  private func bar(index: Int, day: Day, title: String, amount: Int64, offset: Double)
    -> some ChartContent
  {
    RectangleMark(
      xStart: .value("Den období", Double(index + 1) + offset - 0.09),
      xEnd: .value("Den období", Double(index + 1) + offset + 0.09),
      yStart: .value("Kč", 0), yEnd: .value("Kč", Double(amount) / 100)
    )
    .foregroundStyle(by: .value("Typ", title))
    .cornerRadius(4)
    .opacity(selectedIndex == nil || selectedIndex == index + 1 ? 1 : 0.4)
    .accessibilityLabel("\(displayDate(day)) · \(title)")
    .accessibilityValue(Money.format(amount))
  }

  private func select(_ location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
    guard let anchor = proxy.plotFrame else {
      selectedIndex = nil
      return
    }
    let frame = geometry[anchor]
    guard frame.contains(location), let value: Double = proxy.value(atX: location.x - frame.minX)
    else {
      selectedIndex = nil
      return
    }
    let index = Int(value.rounded())
    selectedIndex = points.indices.contains(index - 1) ? index : nil
  }

  private func legend(_ title: String, color: Color) -> some View {
    Label {
      Text(title)
    } icon: {
      RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
    }.font(.callout)
  }

  private func tooltip(_ point: DayExpense) -> some View {
    VStack(alignment: .leading, spacing: 9) {
      Text(displayDate(point.day)).font(.callout.weight(.semibold))
      Divider()
      tooltipRow("Příjmy", amount: income[point.day] ?? 0, color: Palette.income)
      tooltipRow("Výdaje", amount: point.amount, color: Palette.expense)
      tooltipRow("Splátky kreditky", amount: repayments[point.day] ?? 0, color: .indigo)
    }
    .padding(14).frame(width: 250)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.1)))
    .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    .allowsHitTesting(false)
  }

  private func tooltipRow(_ title: String, amount: Int64, color: Color) -> some View {
    HStack {
      Text(title).foregroundStyle(color)
      Spacer()
      MoneyText(amount: amount).fontWeight(.medium)
    }.font(.caption)
  }
}
