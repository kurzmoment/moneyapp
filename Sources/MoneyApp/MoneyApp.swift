import AppKit
import SwiftUI

@main
struct MoneyApp: App {
  @NSApplicationDelegateAdaptor(MoneyAppDelegate.self) private var appDelegate
  @State private var model = AppModel()
  @AppStorage("appearance") private var appearance = "system"

  var body: some Scene {
    WindowGroup {
      RootView(model: model)
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .task { if !model.loaded { await model.load() } }
    }
    .defaultSize(width: 1240, height: 820)
    .windowResizability(.contentMinSize)
    .commands {
      CommandGroup(after: .undoRedo) {
        Button("Vrátit poslední změnu transakce") {
          if let change = model.latestTransactionChange {
            model.run { try await model.undoTransactionChange(change) }
          }
        }
        .keyboardShortcut("z", modifiers: [.command, .option])
        .disabled(model.busy || model.latestTransactionChange == nil)
      }
      CommandGroup(replacing: .newItem) {
        Button("Nová transakce") {
          NotificationCenter.default.post(name: .newTransaction, object: nil)
        }
        .keyboardShortcut("n")
        .disabled(!model.loaded || model.state.accounts.isEmpty || model.busy)
      }
    }
  }
}

extension Notification.Name {
  static let newTransaction = Notification.Name("MoneyApp.newTransaction")
}

@MainActor
final class MoneyAppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
      let icon = NSImage(contentsOf: url)
    else {
      NSLog("MoneyApp: ikonu aplikace nelze načíst z balíčku.")
      return
    }
    NSApplication.shared.applicationIconImage = icon
  }
}
