import Charts
import MoneyCore
import SwiftUI

struct SpendingCategoryBreakdown: View {
  var model: AppModel
  let categories: [CategoryTotal]
  let total: Int64
  let details: SpendingDetails
  @State private var hoveredID: UUID?
  @State private var selectedID: UUID?

  private var highlighted: CategoryTotal? {
    categories.first { $0.id == (hoveredID ?? selectedID) }
  }

  var body: some View {
    Surface {
      HStack {
        VStack(alignment: .leading, spacing: 5) {
          Text("Za co utrácím").font(.headline)
          Text("Podíl na výdajích za vybrané období").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Text("\(categories.count) kategorií").font(.caption).foregroundStyle(.secondary)
      }
      if categories.isEmpty {
        ContentUnavailableView(
          "Zatím žádné výdaje", systemImage: "chart.pie",
          description: Text("V tomto období nejsou evidované žádné výdaje."))
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(alignment: .center, spacing: 32) {
            donut.frame(width: 320)
            categoryList.frame(minWidth: 330)
          }
          VStack(spacing: 24) {
            donut
            categoryList
          }
        }
        Text("Najeďte na výseč nebo kategorii pro detail. Kliknutím zobrazíte platby.")
          .font(.caption).foregroundStyle(.secondary)
        if let category = categories.first(where: { $0.id == selectedID }) {
          Divider()
          HStack {
            Label(category.name, systemImage: category.symbol).font(.headline)
            Spacer()
            MoneyText(amount: category.amount).font(.headline)
            Button("Zavřít detail", systemImage: "xmark") { selectedID = nil }
              .labelStyle(.iconOnly).buttonStyle(.borderless)
          }
          SpendingPaymentList(model: model, payments: details.categoryPayments[category.id] ?? [])
            .id(category.id)
        }
      }
    }
  }

  private var donut: some View {
    Chart(Array(categories.enumerated()), id: \.element.id) { index, category in
      SectorMark(
        angle: .value("Výdaje", Double(category.amount)), innerRadius: .ratio(0.7),
        outerRadius: .ratio(highlighted?.id == category.id ? 1 : 0.96), angularInset: 2
      )
      .cornerRadius(5)
      .foregroundStyle(Palette.chart[index % Palette.chart.count])
      .opacity(highlighted == nil || highlighted?.id == category.id ? 1 : 0.3)
    }
    .chartBackground { _ in
      VStack(spacing: 8) {
        if let highlighted {
          Image(systemName: highlighted.symbol).font(.title2).foregroundStyle(.secondary)
          Text(highlighted.name).font(.callout).foregroundStyle(.secondary)
          MoneyText(amount: highlighted.amount).font(
            .system(size: 25, weight: .semibold, design: .rounded))
          Text(share(highlighted)).font(.callout).foregroundStyle(.secondary)
        } else {
          Text("CELKOVÉ VÝDAJE").font(.caption.weight(.medium)).foregroundStyle(.secondary)
          MoneyText(amount: total).font(.system(size: 25, weight: .semibold, design: .rounded))
          Text("Za vybrané období").font(.caption).foregroundStyle(.secondary)
        }
      }.frame(width: 200).multilineTextAlignment(.center).allowsHitTesting(false)
    }
    .chartOverlay { proxy in
      GeometryReader { geometry in
        Rectangle().fill(.clear).contentShape(Rectangle())
          .onContinuousHover { phase in
            switch phase {
            case .active(let location):
              hoveredID = category(at: location, proxy: proxy, geometry: geometry)
            case .ended: hoveredID = nil
            }
          }
          .onTapGesture { location in
            if let id = category(at: location, proxy: proxy, geometry: geometry) { toggle(id) }
          }
      }
    }
    .frame(height: 320)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Rozdělení výdajů. Kategorie a jejich platby jsou dostupné v seznamu.")
    .accessibilityValue(Money.format(total))
  }

  private var categoryList: some View {
    VStack(spacing: 4) {
      ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
        let color = Palette.chart[index % Palette.chart.count]
        Button {
          toggle(category.id)
        } label: {
          HStack(spacing: 12) {
            Image(systemName: category.symbol).font(.body)
              .foregroundStyle(color).frame(width: 34, height: 34)
              .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
              Text(category.name).font(.callout.weight(.medium)).foregroundStyle(.primary)
              GeometryReader { geometry in
                Capsule().fill(color.opacity(0.1))
                Capsule().fill(color).frame(
                  width: geometry.size.width
                    * NSDecimalNumber(decimal: category.share(of: total)).doubleValue)
              }.frame(height: 3).accessibilityHidden(true)
            }
            Spacer(minLength: 16)
            VStack(alignment: .trailing, spacing: 4) {
              MoneyText(amount: category.amount).font(.callout.weight(.semibold)).foregroundStyle(
                .primary)
              Text(share(category)).font(.caption).foregroundStyle(.secondary)
            }
            Image(systemName: selectedID == category.id ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
          }
          .padding(10).contentShape(RoundedRectangle(cornerRadius: 12))
          .background(
            highlighted?.id == category.id ? Palette.canvas : Color.clear,
            in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredID = hovering ? category.id : nil }
        .accessibilityLabel(
          "\(category.name), \(Money.format(category.amount)), \(share(category))"
        )
        .accessibilityValue(selectedID == category.id ? "Detail otevřen" : "Detail zavřen")
        .accessibilityHint("Zobrazí konkrétní platby v kategorii")
      }
    }
  }

  private func share(_ category: CategoryTotal) -> String {
    category.share(of: total).formatted(
      .percent.precision(.fractionLength(1)).locale(Locale(identifier: "cs_CZ")))
  }

  private func toggle(_ id: UUID) { selectedID = selectedID == id ? nil : id }

  /// Pointer geometry is display-only; money and category totals remain exact minor units.
  private func category(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> UUID? {
    guard let anchor = proxy.plotFrame, total > 0 else { return nil }
    let frame = geometry[anchor]
    let x = location.x - frame.midX
    let y = location.y - frame.midY
    let radius = min(frame.width, frame.height) / 2
    let distance = hypot(x, y)
    guard distance >= radius * 0.7, distance <= radius else { return nil }
    var angle = atan2(x, -y)
    if angle < 0 { angle += 2 * .pi }
    let fraction = angle / (2 * .pi)
    var boundary = 0.0
    for category in categories {
      boundary += NSDecimalNumber(decimal: category.share(of: total)).doubleValue
      if fraction < boundary { return category.id }
    }
    return categories.last?.id
  }
}
