import AppKit

/// 初回（対話）起動時に使い方を一度だけ案内する（§11）。
/// 右クリックは macOS Services として自動登録されるため、ユーザー側の有効化操作は不要。
enum Onboarding {
    private static let shownKey = "NeatZipOnboardingShown"

    static func showIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        let alert = NSAlert()
        alert.messageText = String(localized: "onboarding.title")
        alert.informativeText = String(localized: "onboarding.body")
        alert.addButton(withTitle: String(localized: "onboarding.gotIt"))
        alert.runModal()
    }
}
