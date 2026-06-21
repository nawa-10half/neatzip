import AppKit
import CleanZipKit

/// クリーンZIP 作成中に出す進捗パネル（AppKit）。ZipController と同じく AppKit で統一。
///
/// - `show()` / `update(_:)` / `finish()` は **メインスレッド**から呼ぶ。
/// - `isCancelled` だけはバックグラウンドの圧縮ループから読まれるためロックで保護する。
/// - 単一ファイル（`totalFiles <= 1`）はファイル内途中経過を出せないので不確定バーにする。
final class ProgressController {

    // キャンセルフラグはワーカースレッドから読むためスレッドセーフに。
    private let lock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }

    private var panel: NSPanel?
    private var bar: NSProgressIndicator!
    private var detail: NSTextField!
    private var headline: NSTextField!
    private var cancelButton: NSButton!
    private var latest: CleanZipProgress?   // show() 前に届いた最新値を表示へ反映する

    // MARK: - ライフサイクル（メインスレッド）

    /// パネルを生成して前面に出す（多重呼び出しは無視）。
    func show() {
        guard panel == nil else { return }

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 120))

        headline = Self.label(frame: NSRect(x: 16, y: 88, width: 408, height: 18),
                              string: "クリーンZIPを作成中…", bold: true)
        bar = NSProgressIndicator(frame: NSRect(x: 16, y: 62, width: 408, height: 16))
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        detail = Self.label(frame: NSRect(x: 16, y: 36, width: 408, height: 16),
                            string: "", bold: false)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle

        cancelButton = NSButton(frame: NSRect(x: 336, y: 6, width: 88, height: 28))
        cancelButton.title = "キャンセル"
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Esc でキャンセル
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        for v in [headline, bar, detail, cancelButton] as [NSView] { content.addSubview(v) }

        let p = NSPanel(contentRect: content.frame,
                        styleMask: [.titled],   // 閉じるボタンなし＝キャンセル経由のみ
                        backing: .buffered, defer: false)
        p.title = "NeatZip"
        p.contentView = content
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.center()
        panel = p

        if let latest { apply(latest) }
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 進捗を反映（パネル未表示なら最新値だけ保持し、show() 時に反映）。
    func update(_ progress: CleanZipProgress) {
        latest = progress
        guard panel != nil else { return }
        apply(progress)
    }

    /// パネルを閉じる。
    func finish() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    // MARK: - 内部

    private func apply(_ p: CleanZipProgress) {
        if p.totalFiles <= 1 {
            // 単一ファイル: 途中経過を出せないのでバーバーポール。
            if !bar.isIndeterminate {
                bar.isIndeterminate = true
                bar.startAnimation(nil)
            }
            detail.stringValue = p.currentName.isEmpty
                ? "まもなく完了します…"
                : "圧縮中: \(displayName(p.currentName))"
        } else {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = p.fraction
            let pct = Int((p.fraction * 100).rounded())
            var line = "\(p.completedFiles) / \(p.totalFiles) ファイル ・ \(pct)%"
            if !p.currentName.isEmpty { line += " ・ \(displayName(p.currentName))" }
            detail.stringValue = line
        }
    }

    @objc private func cancelClicked() {
        lock.lock(); _cancelled = true; lock.unlock()
        headline.stringValue = "キャンセル中…"
        cancelButton.isEnabled = false
    }

    /// zip 内パス（"Folder/sub/photo.jpg"）から表示用にファイル名だけ取り出す。
    private func displayName(_ zipPath: String) -> String {
        zipPath.split(separator: "/").last.map(String.init) ?? zipPath
    }

    private static func label(frame: NSRect, string: String, bold: Bool) -> NSTextField {
        let f = NSTextField(frame: frame)
        f.stringValue = string
        f.isEditable = false
        f.isBordered = false
        f.drawsBackground = false
        f.isSelectable = false
        f.font = bold ? .boldSystemFont(ofSize: 13) : .systemFont(ofSize: 13)
        return f
    }
}
