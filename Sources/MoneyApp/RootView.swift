import MoneyCore
import SwiftUI

enum Destination: String, CaseIterable, Identifiable {
  case overview = "Přehled"
  case transactions = "Transakce"
  case budgets = "Rozpočty"
  case recurring = "Pravidelné platby"
  case accounts = "Účty"
  case loans = "Půjčky"
  case investments = "Investice"
  case goals = "Cíle spoření"
  case history = "Historie změn"
  case settings = "Nastavení"
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .overview: "chart.pie"
    case .transactions: "arrow.left.arrow.right"
    case .budgets: "chart.bar.xaxis"
    case .recurring: "repeat"
    case .accounts: "wallet.bifold"
    case .loans: "person.2"
    case .investments: "chart.line.uptrend.xyaxis"
    case .goals: "target"
    case .history: "clock.arrow.circlepath"
    case .settings: "gearshape"
    }
  }
}

struct RootView: View {
  @Bindable var model: AppModel
  @State private var destination: Destination? = .overview
  @State private var addingTransaction = false
  @State private var addingAccount = false

  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
          IconBadge(symbol: "chart.bar.xaxis.ascending")
          VStack(alignment: .leading, spacing: 2) {
            Text("MoneyApp").font(.title3.bold())
            Text("Můj finanční prostor").font(.caption).foregroundStyle(.secondary)
          }
        }.padding(20).padding(.top, 10)
        List(selection: $destination) {
          Section("MOJE FINANCE") {
            ForEach(Destination.allCases.filter { $0 != .settings }) { item in
              Label(item.rawValue, systemImage: item.symbol).padding(.vertical, 5).tag(item)
            }
          }
          Section {
            Label(Destination.settings.rawValue, systemImage: Destination.settings.symbol).tag(
              Destination.settings)
          }
        }.listStyle(.sidebar)
        VStack(alignment: .leading, spacing: 6) {
          Label(
            model.isDemo ? "Ukázkový režim" : "Jen na tomto Macu",
            systemImage: model.isDemo ? "sparkles" : "lock.shield"
          )
          .font(.caption.weight(.medium))
          Text(model.isDemo ? "Oddělená dočasná data" : "Soukromé finance • CZK").font(.caption)
            .foregroundStyle(.secondary)
        }.padding(20)
      }.navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 280)
    } detail: {
      Group {
        if !model.loaded {
          if model.errorMessage != nil {
            ContentUnavailableView {
              Label("Data nejsou dostupná", systemImage: "externaldrive.badge.exclamationmark")
            } description: {
              Text("Zkontrolujte přístup k úložišti a zkuste načtení znovu.")
            } actions: {
              Button("Zkusit znovu") { Task { await model.load() } }
            }
          } else {
            ProgressView("Načítání financí…").frame(maxWidth: .infinity, maxHeight: .infinity)
          }
        } else {
          switch destination ?? .overview {
          case .overview:
            DashboardView(
              model: model, addTransaction: { addingTransaction = true },
              addAccount: { addingAccount = true })
          case .transactions: TransactionsView(model: model)
          case .budgets: BudgetsView(model: model)
          case .recurring: RecurringView(model: model)
          case .accounts: AccountsView(model: model)
          case .loans: LoansView(model: model)
          case .investments: InvestmentsView(model: model)
          case .goals: SavingsGoalsView(model: model)
          case .history: TransactionHistoryView(model: model)
          case .settings: SettingsView(model: model)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background(Palette.canvas)
      .toolbar {
        ToolbarItem(placement: .primaryAction) {
          if model.busy { ProgressView().controlSize(.small) }
          Button {
            if model.state.accounts.isEmpty {
              addingAccount = true
            } else {
              addingTransaction = true
            }
          } label: {
            Label(
              model.state.accounts.isEmpty ? "Přidat účet" : "Nová transakce", systemImage: "plus")
          }.disabled(!model.loaded || model.busy)
        }
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if model.isDemo || model.statusMessage != nil {
          HStack {
            Label(
              model.isDemo
                ? "UKÁZKA — změny neovlivní vaše skutečná data" : model.statusMessage ?? "",
              systemImage: model.isDemo ? "eye" : "checkmark.circle"
            )
            .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !model.isDemo {
              Button {
                model.statusMessage = nil
              } label: {
                Image(systemName: "xmark")
              }
              .buttonStyle(.plain).accessibilityLabel("Zavřít oznámení")
            }
          }.padding(.horizontal, 24).padding(.vertical, 8).background(.bar)
        }
      }
    }
    .tint(Palette.accent)
    .frame(minWidth: 960, minHeight: 650)
    .sheet(isPresented: $addingTransaction) { TransactionEditor(model: model) }
    .sheet(isPresented: $addingAccount) { AccountEditor(model: model) }
    .alert(
      "Operaci se nepodařilo dokončit",
      isPresented: Binding(
        get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    ) {
      Button("Rozumím") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .onReceive(NotificationCenter.default.publisher(for: .newTransaction)) { _ in
      if model.loaded && !model.state.accounts.isEmpty && !model.busy { addingTransaction = true }
    }
  }
}
