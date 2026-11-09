import MoneyCore
import SwiftUI

struct SettingsView: View {
  var model: AppModel
  @AppStorage("appearance") private var appearance = "system"
  @State private var categoryName = ""
  @State private var categorySymbol = "tag"
  @State private var choosingCategoryIcon = false
  @State private var editingCategory: MoneyCore.Category?
  @State private var deletingCategory: MoneyCore.Category?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        PageHeader(title: "Nastavení", subtitle: "Vaše data, vaše kategorie, váš způsob práce.")
        Surface {
          HStack(spacing: 12) {
            IconBadge(symbol: "circle.lefthalf.filled")
            Text("Vzhled aplikace").font(.headline)
          }
          Picker("Barevný režim", selection: $appearance) {
            Text("Podle systému").tag("system")
            Text("Světlý").tag("light")
            Text("Tmavý").tag("dark")
          }.pickerStyle(.segmented).frame(maxWidth: 420)
        }
        Surface {
          HStack(spacing: 12) {
            IconBadge(symbol: "externaldrive")
            Text("Data a zálohy").font(.headline)
          }
          Text(
            "Data zůstávají lokálně. Automatické zálohy uchovávají posledních 7 dní, kdy jste aplikaci otevřeli. Pro ochranu při ztrátě Macu ukládejte úplnou zálohu také na jiné úložiště."
          )
          .font(.callout).foregroundStyle(.secondary)
          HStack {
            Button("Exportovat CSV") { model.run { try await model.exportData(backup: false) } }
            Button("Uložit úplnou zálohu") {
              model.run { try await model.exportData(backup: true) }
            }
            Button("Obnovit ze zálohy") { model.run { try await model.restoreData() } }
          }.disabled(model.busy)
          Button("Zobrazit úložiště ve Finderu") { model.revealData() }.buttonStyle(.link)
          Text(
            "CSV obsahuje transakce. Úplná záloha zahrnuje také účty, kategorie, rozpočty a pravidelné platby."
          ).font(.caption).foregroundStyle(.secondary)
        }
        Surface {
          HStack(spacing: 12) {
            IconBadge(symbol: "tag")
            Text("Kategorie").font(.headline)
          }
          HStack {
            Button {
              choosingCategoryIcon = true
            } label: {
              Label("Ikona: \(categoryIconLabel(categorySymbol))", systemImage: categorySymbol)
                .frame(minWidth: 132, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .help("Vybrat ikonu kategorie")
            .accessibilityLabel("Vybrat ikonu kategorie")
            .disabled(model.busy)
            .popover(isPresented: $choosingCategoryIcon, arrowEdge: .bottom) {
              CategoryIconPicker(selection: $categorySymbol)
                .disabled(model.busy)
            }
            TextField(
              editingCategory == nil ? "Název nové kategorie" : "Nový název kategorie",
              text: $categoryName
            ).textFieldStyle(.roundedBorder)
              .onSubmit { saveCategory() }
            Button(editingCategory == nil ? "Přidat" : "Uložit", action: saveCategory)
              .disabled(
                categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            if editingCategory != nil {
              Button("Zrušit") {
                resetCategoryEditor()
              }
            }
          }
          .disabled(model.busy)
          ForEach(model.state.categories) { category in
            HStack(spacing: 12) {
              IconBadge(symbol: category.symbol, color: Palette.accent)
              Text(category.name)
              Spacer()
              Button("Upravit") { beginEditing(category) }
              Button(role: .destructive) {
                deletingCategory = category
              } label: {
                Image(systemName: "trash")
              }
              .accessibilityLabel("Odstranit kategorii \(category.name)")
            }
            .disabled(model.busy)
          }
        }
        Text("MoneyApp • osobní finance • CZK\nBez účtu, bez reklam, bez odesílání finančních dat.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .frame(maxWidth: 1200, alignment: .top)
      .frame(maxWidth: .infinity, alignment: .top)
      .padding(28)
    }
    .confirmationDialog(
      "Odstranit kategorii?",
      isPresented: Binding(
        get: { deletingCategory != nil }, set: { if !$0 { deletingCategory = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let category = deletingCategory {
          model.run { try await model.deleteCategory(category) }
        }
        deletingCategory = nil
      }
    } message: {
      Text("Používanou kategorii nelze odstranit. Její přejmenování se projeví i v historii.")
    }
  }

  private func saveCategory() {
    guard !model.busy else { return }
    var category = editingCategory ?? MoneyCore.Category(name: "")
    category.name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    category.symbol = categorySymbol
    let value = category
    model.run {
      try await model.saveCategory(value)
      resetCategoryEditor()
    }
  }

  private func beginEditing(_ category: MoneyCore.Category) {
    editingCategory = category
    categoryName = category.name
    categorySymbol = category.symbol
    choosingCategoryIcon = false
  }

  private func resetCategoryEditor() {
    editingCategory = nil
    categoryName = ""
    categorySymbol = "tag"
    choosingCategoryIcon = false
  }
}

private struct CategoryIconPicker: View {
  @Binding var selection: String
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Ikona kategorie").font(.headline)
      Text("Vyberte symbol, který bude vidět u transakcí a přehledů.")
        .font(.caption).foregroundStyle(.secondary)
      LazyVGrid(
        columns: Array(repeating: GridItem(.fixed(60), spacing: 8), count: 5), spacing: 8
      ) {
        ForEach(CategoryIconChoice.all) { icon in
          Button {
            selection = icon.symbol
            dismiss()
          } label: {
            VStack(spacing: 5) {
              Image(systemName: icon.symbol)
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(selection == icon.symbol ? Palette.onHero : Palette.accent)
                .background(
                  selection == icon.symbol ? Palette.accent : Palette.accent.opacity(0.12),
                  in: RoundedRectangle(cornerRadius: 9)
                )
              Text(icon.label)
                .font(.system(size: 10))
                .lineLimit(1)
                .frame(width: 58)
            }
          }
          .buttonStyle(.plain)
          .help(icon.label)
          .accessibilityLabel("Ikona \(icon.label)")
          .accessibilityAddTraits(selection == icon.symbol ? .isSelected : [])
        }
      }
    }
    .padding(18)
    .frame(width: 370)
  }
}

private struct CategoryIconChoice: Identifiable {
  static let all: [CategoryIconChoice] = [
    CategoryIconChoice("tag", "Ostatní"),
    CategoryIconChoice("basket", "Potraviny"),
    CategoryIconChoice("house", "Bydlení"),
    CategoryIconChoice("tram", "Doprava"),
    CategoryIconChoice("fork.knife", "Restaurace"),
    CategoryIconChoice("sparkles", "Volný čas"),
    CategoryIconChoice("heart", "Zdraví"),
    CategoryIconChoice("bag", "Nákupy"),
    CategoryIconChoice("repeat", "Předplatné"),
    CategoryIconChoice("briefcase", "Výplata"),
    CategoryIconChoice("car.fill", "Auto"),
    CategoryIconChoice("fuelpump.fill", "Palivo"),
    CategoryIconChoice("bolt.fill", "Energie"),
    CategoryIconChoice("wifi", "Internet"),
    CategoryIconChoice("phone.fill", "Telefon"),
    CategoryIconChoice("graduationcap.fill", "Vzdělávání"),
    CategoryIconChoice("pawprint.fill", "Mazlíčci"),
    CategoryIconChoice("airplane", "Cestování"),
    CategoryIconChoice("gift.fill", "Dárky"),
    CategoryIconChoice("gamecontroller.fill", "Hry"),
    CategoryIconChoice("music.note", "Hudba"),
    CategoryIconChoice("figure.2.and.child.holdinghands", "Rodina"),
    CategoryIconChoice("cross.case.fill", "Lékárna"),
    CategoryIconChoice("banknote.fill", "Hotovost"),
    CategoryIconChoice("creditcard.fill", "Karta"),
    CategoryIconChoice("chart.line.uptrend.xyaxis", "Investice"),
    CategoryIconChoice("building.columns.fill", "Banka"),
    CategoryIconChoice("scalemass.fill", "Poplatky"),
  ]

  let symbol: String
  let label: String
  var id: String { symbol }

  init(_ symbol: String, _ label: String) {
    self.symbol = symbol
    self.label = label
  }
}

private func categoryIconLabel(_ symbol: String) -> String {
  CategoryIconChoice.all.first { $0.symbol == symbol }?.label ?? "Vlastní"
}
