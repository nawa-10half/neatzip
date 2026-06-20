import AppKit
import CleanZipKit

final class ZipController {
    static let shared = ZipController()
    private init() {}

    func begin(with items: [URL]) {
        guard let dest = CleanZip.suggestedDestination(for: items) else { return }
        let r = promptOptions()
        guard r.proceed else { return }
        run(items: items, to: dest,
            options: CleanZipOptions(password: r.password, encryption: r.encryption))
    }

    private func promptOptions() -> (password: String?, encryption: ZipEncryption, proceed: Bool) {
        let alert = NSAlert()
        alert.messageText = "NeatZip でクリーンZIPを作成"
        alert.informativeText = "パスワード（空なら暗号化なし）"
        alert.addButton(withTitle: "作成")
        alert.addButton(withTitle: "キャンセル")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        popup.addItems(withTitles: ["標準（ZipCrypto・互換重視）", "AES-256（強力）"])
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(field); box.addSubview(popup)
        alert.accessoryView = box

        let proceed = alert.runModal() == .alertFirstButtonReturn
        let pw = field.stringValue.isEmpty ? nil : field.stringValue
        let enc: ZipEncryption = pw == nil ? .none
            : (popup.indexOfSelectedItem == 1 ? .aes256 : .zipCrypto)
        return (pw, enc, proceed)
    }

    private func run(items: [URL], to dest: URL, options: CleanZipOptions) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CleanZip.make(items: items, to: dest, options: options)
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
        }
    }
}
