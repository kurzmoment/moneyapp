import MoneyCore
import SwiftUI

enum Palette {
  static let accent = adaptive(light: 0x176D65, dark: 0x70CFC0)
  static let income = adaptive(light: 0x176D65, dark: 0x70CFC0)
  static let expense = adaptive(light: 0xB85B2A, dark: 0xF1AE78)
  static let surface = adaptive(light: 0xFFFFFF, dark: 0x242C2D)
  static let canvas = adaptive(light: 0xF2F5F3, dark: 0x192122)
  static let hero = Color(red: 0.08, green: 0.22, blue: 0.21)
  static let heroEnd = Color(red: 0.13, green: 0.34, blue: 0.30)
  static let onHero = Color.white

  private static func adaptive(light: UInt32, dark: UInt32) -> Color {
    Color(
      nsColor: NSColor(name: nil) { appearance in
        let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(
          srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255,
          blue: Double(value & 255) / 255, alpha: 1)
      })
  }
  static let chart: [Color] = [
    accent, expense, .indigo, .pink, .blue, .purple, .brown, .cyan, .gray, .mint,
  ]
}

struct Surface<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 18) { content }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 20))
      .overlay(RoundedRectangle(cornerRadius: 20).stroke(.primary.opacity(0.06), lineWidth: 1))
      .shadow(color: .black.opacity(0.025), radius: 12, y: 4)
      .accessibilityElement(children: .contain)
  }
}

struct PageHeader: View {
  var title: String
  var subtitle: String
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 28, weight: .bold))
      Text(subtitle).font(.callout).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .combine)
  }
}

struct MoneyText: View {
  var amount: Int64
  var body: some View { Text(Money.format(amount)).monospacedDigit() }
}

struct MonthControl: View {
  var model: AppModel
  var body: some View {
    HStack(spacing: 12) {
      Button {
        model.moveMonth(-1)
      } label: {
        Image(systemName: "chevron.left")
      }
      .help("Předchozí měsíc").accessibilityLabel("Předchozí měsíc")
      Text(
        Day(rawValue: model.month + "-01").date.formatted(
          .dateTime.month(.wide).year().locale(Locale(identifier: "cs_CZ")))
      )
      .font(.headline).frame(minWidth: 125)
      Button {
        model.moveMonth(1)
      } label: {
        Image(systemName: "chevron.right")
      }
      .help("Následující měsíc").accessibilityLabel("Následující měsíc")
      Button("Dnes") {
        model.month = Day.today.month
        model.refreshReport()
      }
      .disabled(model.month == Day.today.month)
    }.buttonStyle(.borderless)
      .fixedSize(horizontal: true, vertical: false)
      .padding(10)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
  }
}

func displayDate(_ day: Day) -> String {
  day.date.formatted(.dateTime.day().month().year().locale(Locale(identifier: "cs_CZ")))
}

struct IconBadge: View {
  var symbol: String
  var color: Color = Palette.accent
  var body: some View {
    Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
      .foregroundStyle(color).frame(width: 36, height: 36)
      .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
      .accessibilityHidden(true)
  }
}
