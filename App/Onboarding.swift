import AppKit

/// 初回起動時に Finder 拡張の有効化方法を案内する（§11）。
enum Onboarding {
    private static let shownKey = "NeatZipOnboardingShown"

    static func showIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = String(localized: "onboarding.title")
        alert.informativeText = String(localized: "onboarding.body")
        alert.addButton(withTitle: String(localized: "onboarding.openSettings"))
        alert.addButton(withTitle: String(localized: "onboarding.later"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }
}
