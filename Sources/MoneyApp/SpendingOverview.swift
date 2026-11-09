import Charts
import MoneyCore
import SwiftUI

struct SpendingOverview: View {
  var model: AppModel
  let categories: [CategoryTotal]
  let total: Int64
  let details: SpendingDetails

  var body: some View {
    SpendingCategoryBreakdown(model: model, categories: categories, total: total, details: details)
    Surface {
      Text("Největší výdaje").font(.headline)
      Text(
        "Platby od nejvyšší částky za vybrané období. Rozdělený výdaj je zde uveden jednou v celé výši."
      )
      .font(.callout).foregroundStyle(.secondary)
      SpendingPaymentList(model: model, transactions: details.expenses)
    }
    Surface {
      Text("Převody a splátky kreditky").font(.headline)
      Text(
        "Pohyby mezi vlastními účty za vybrané období. Nezvyšují výdaje; nákupy kreditkou jsou zahrnuté v kategoriích výše."
      )
      .font(.callout).foregroundStyle(.secondary)
      DisclosureGroup {
        SpendingPaymentList(model: model, transactions: details.creditRepayments)
      } label: {
        movementLabel(
          "Splátky kreditky", total: details.creditRepaymentTotal,
          count: details.creditRepayments.count)
      }
      DisclosureGroup {
        SpendingPaymentList(model: model, transactions: details.transfers)
      } label: {
        movementLabel(
          "Ostatní převody", total: details.transferTotal, count: details.transfers.count)
      }
    }
  }

  private func movementLabel(_ title: String, total: Int64, count: Int) -> some View {
    HStack {
      Text("\(title) (\(count))")
      Spacer()
      MoneyText(amount: total).fontWeight(.semibold)
    }.padding(.vertical, 6)
  }
}

struct SpendingPaymentList: View {
  var model: AppModel
  let payments: [SpendingPayment]
  @State private var page = 0
  private let pageSize = 10

  init(model: AppModel, payments: [SpendingPayment]) {
    self.model = model
    self.payments = payments
  }

  init(model: AppModel, transactions: [MoneyCore.Transaction]) {
    self.init(
      model: model,
      payments: transactions.map { SpendingPayment(transaction: $0, amount: $0.amount) })
  }

  var body: some View {
    let lastPage = max((payments.count - 1) / pageSize, 0)
    let currentPage = min(page, lastPage)
    if payments.isEmpty {
      Text("V tomto období nejsou žádné platby.")
        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
    } else {
      VStack(spacing: 12) {
        ForEach(payments.dropFirst(currentPage * pageSize).prefix(pageSize)) { payment in
          let transaction = payment.transaction
          HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
              Text(transaction.note.isEmpty ? transaction.kind.title : transaction.note)
                .fontWeight(.medium).textSelection(.enabled)
              Text(
                "\(displayDate(transaction.day)) · \(model.accountName(transaction.accountID))\(transaction.destinationAccountID.map { " → " + model.accountName($0) } ?? "")"
              )
              .foregroundStyle(.secondary)
              if transaction.kind == .expense {
                Text(model.transactionCategoryName(transaction)).foregroundStyle(.secondary)
              }
              if payment.amount != transaction.amount {
                Text("Část rozdělené platby · celkem \(Money.format(transaction.amount))")
                  .foregroundStyle(.secondary)
              }
            }
            Spacer(minLength: 8)
            MoneyText(amount: payment.amount).fontWeight(.semibold)
          }
          .font(.callout).accessibilityElement(children: .combine)
          Divider()
        }
        HStack {
          Text("Počet plateb: \(payments.count)").foregroundStyle(.secondary)
          Spacer()
          if lastPage > 0 {
            Button("Předchozí") { page = currentPage - 1 }.disabled(currentPage == 0)
            Text("\(currentPage + 1) / \(lastPage + 1)").monospacedDigit()
            Button("Další") { page = currentPage + 1 }.disabled(currentPage == lastPage)
          }
        }.font(.caption)
      }.padding(.vertical, 10)
    }
  }
}
