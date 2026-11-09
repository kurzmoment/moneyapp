import MoneyCore
import SwiftUI

struct TransactionsView: View {
  var model: AppModel
  @State private var search = ""
  @State private var accountFilter: UUID?
  @State private var categoryFilter: UUID?
  @State private var kindFilter: TransactionKind?
  @State private var allHistory = false
  @State private var page = 0
  @State private var editing: MoneyCore.Transaction?
  @State private var deleting: MoneyCore.Transaction?
  @State private var adding = false
  private let pageSize = 50

  private var filtered: [MoneyCore.Transaction] {
    model.state.transactions.filter { transaction in
      (allHistory || transaction.day.month == model.month)
        && (accountFilter == nil || transaction.accountID == accountFilter
          || transaction.destinationAccountID == accountFilter)
        && (categoryFilter == nil || transaction.categoryID == categoryFilter
          || (transaction.splits ?? []).contains { $0.categoryID == categoryFilter })
        && (kindFilter == nil || transaction.kind == kindFilter)
        && (search.isEmpty || transaction.note.localizedStandardContains(search)
          || model.transactionCategoryName(transaction).localizedStandardContains(search))
    }.sorted { $0.day == $1.day ? $0.id.uuidString < $1.id.uuidString : $0.day > $1.day }
  }

  var body: some View {
    let items = filtered
    let lastPage = max((items.count - 1) / pageSize, 0)
    let currentPage = min(page, lastPage)
    let visible = Array(items.dropFirst(currentPage * pageSize).prefix(pageSize))
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        PageHeader(title: "Transakce", subtitle: "Každý pohyb má své místo. I ten ze včerejška.")
        Spacer()
        MonthControl(model: model).disabled(allHistory)
      }
      if let change = model.latestTransactionChange {
        HStack {
          Button("Vrátit poslední změnu", systemImage: "arrow.uturn.backward") {
            model.run { try await model.undoTransactionChange(change) }
          }.disabled(model.busy)
          Text("Podrobnosti v Historii změn").font(.caption).foregroundStyle(.secondary)
        }
      }
      Surface {
        HStack(spacing: 10) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Hledat poznámku nebo kategorii", text: $search)
            .textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 10))
        HStack(alignment: .top, spacing: 16) {
          VStack(alignment: .leading, spacing: 6) {
            Text("Účet").font(.caption).foregroundStyle(.secondary)
            Picker("Účet", selection: $accountFilter) {
              Text("Všechny účty").tag(nil as UUID?)
              ForEach(model.state.accounts) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().accessibilityLabel("Filtrovat podle účtu")
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 6) {
            Text("Kategorie").font(.caption).foregroundStyle(.secondary)
            Picker("Kategorie", selection: $categoryFilter) {
              Text("Všechny kategorie").tag(nil as UUID?)
              ForEach(model.state.categories) { Text($0.name).tag(Optional($0.id)) }
            }.labelsHidden().accessibilityLabel("Filtrovat podle kategorie")
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxWidth: .infinity, alignment: .leading)
          VStack(alignment: .leading, spacing: 6) {
            Text("Typ").font(.caption).foregroundStyle(.secondary)
            Picker("Typ", selection: $kindFilter) {
              Text("Všechny typy").tag(nil as TransactionKind?)
              ForEach(TransactionKind.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
            }.labelsHidden().accessibilityLabel("Filtrovat podle typu")
              .frame(maxWidth: .infinity, alignment: .leading)
          }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.large)
        Toggle("Celá historie", isOn: $allHistory).toggleStyle(.checkbox)
          .font(.callout)

      }
      if items.isEmpty {
        ContentUnavailableView {
          Label("Žádné transakce", systemImage: "tray")
        } description: {
          Text("Přidejte první pohyb nebo změňte vybrané filtry.")
        } actions: {
          Button("Přidat transakci") { adding = true }.disabled(model.state.accounts.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(visible) { transaction in
          HStack(spacing: 14) {
            IconBadge(
              symbol: transaction.kind == .transfer
                ? "arrow.left.arrow.right" : model.categorySymbol(transaction.categoryID),
              color: transaction.kind == .income ? Palette.income : Palette.accent
            )
            VStack(alignment: .leading, spacing: 4) {
              Text(transaction.note.isEmpty ? transaction.kind.title : transaction.note).font(
                .body.weight(.medium)
              ).lineLimit(1)
              if transaction.isSalary == true {
                Label("Výplata · začátek období", systemImage: "calendar.badge.clock")
                  .font(.caption).foregroundStyle(Palette.accent)
              }
              Text(
                "\(model.transactionCategoryName(transaction)) · \(model.accountName(transaction.accountID))\(transaction.destinationAccountID.map { " → " + model.accountName($0) } ?? "")"
              )
              .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
              MoneyText(amount: transaction.amount).fontWeight(.semibold)
              Text("\(transaction.kind.title) · \(displayDate(transaction.day))").font(.caption)
                .foregroundStyle(.secondary)
            }
            Button {
              editing = transaction
            } label: {
              Image(systemName: "pencil")
            }
            .buttonStyle(.borderless).help("Upravit transakci").accessibilityLabel(
              "Upravit \(transaction.note)")
            Button(role: .destructive) {
              deleting = transaction
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless).help("Odstranit transakci").accessibilityLabel(
              "Odstranit \(transaction.note)")
          }.padding(.vertical, 8)
        }.listStyle(.inset).clipShape(RoundedRectangle(cornerRadius: 14))
        HStack {
          Text("\(items.count) transakcí").foregroundStyle(.secondary)
          Spacer()
          Button("Předchozí") { page = max(currentPage - 1, 0) }.disabled(currentPage == 0)
          Text("\(currentPage + 1) / \(lastPage + 1)").monospacedDigit()
          Button("Další") { page = currentPage + 1 }.disabled(currentPage >= lastPage)
        }.font(.callout)
      }
    }
    .frame(maxWidth: 1200, alignment: .top)
    .frame(maxWidth: .infinity, alignment: .top)
    .padding(28)
    .onChange(of: search) { page = 0 }
    .onChange(of: accountFilter) { page = 0 }
    .onChange(of: categoryFilter) { page = 0 }
    .onChange(of: kindFilter) { page = 0 }
    .onChange(of: allHistory) { page = 0 }
    .onChange(of: model.month) { page = 0 }
    .sheet(isPresented: $adding) { TransactionEditor(model: model) }
    .sheet(item: $editing) { TransactionEditor(model: model, transaction: $0) }
    .confirmationDialog(
      "Odstranit transakci?",
      isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
      titleVisibility: .visible
    ) {
      Button("Odstranit", role: .destructive) {
        if let transaction = deleting {
          model.run { try await model.deleteTransaction(transaction) }
        }
        deleting = nil
      }
    } message: {
      Text(
        "Pohyb se odebere z přehledů i zůstatku. U pravidelné platby bude tento výskyt znovu čekat na potvrzení."
      )
    }
  }
}
