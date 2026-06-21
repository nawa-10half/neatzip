import AppKit
import CleanZipKit

final class ZipController {
    static let shared = ZipController()
    private init() {}

    /// 走行中ジョブ数。右クリック起動（quitWhenDone）の早期終了が、別の進行中ジョブを
    /// 巻き込まないよう数える（オプションダイアログはモーダルだが圧縮は並行しうる）。
    private var activeJobs = 0

    /// `quitWhenDone` は Finder 右クリック（neatzip:// handoff）起動のとき true。
    /// その場合は処理を終えた後にアプリを終了する（一回限りのヘルパーとして振る舞う）。
    func begin(with items: [URL], quitWhenDone: Bool = false) {
        guard let dest = CleanZip.suggestedDestination(for: items) else {
            if quitWhenDone { NSApp.terminate(nil) }
            return
        }
        let r = promptOptions()
        guard r.proceed else {
            if quitWhenDone { NSApp.terminate(nil) }   // ダイアログでキャンセル → 残らず終了
            return
        }
        run(items: items, to: dest,
            options: CleanZipOptions(password: r.password, encryption: r.encryption),
            quitWhenDone: quitWhenDone)
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

    private func run(items: [URL], to dest: URL, options: CleanZipOptions, quitWhenDone: Bool) {
        activeJobs += 1
        let pc = ProgressController()
        var finished = false   // 遅延表示と完了の両方がメインスレッドで触る

        // 各終了経路（完了 / キャンセル / エラー）の末尾でメインスレッドから呼ぶ共通処理。
        // 右クリック起動で、かつ他に走っているジョブが無ければ、結果を見せてからアプリ終了。
        let conclude = {
            self.activeJobs -= 1
            if quitWhenDone && self.activeJobs == 0 {
                // Finder への表示要求が落ち着くまで一拍おいてから終了する。
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSApp.terminate(nil) }
            }
        }

        // すぐ終わるジョブでウィンドウがちらつかないよう、少し待ってから出す。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if !finished { pc.show() }
        }

        // UI 更新は ~30fps に間引く（大量小ファイルでメインキューを溢れさせない）。
        var lastTick: UInt64 = 0
        let throttleNs: UInt64 = 33_000_000

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try CleanZip.make(
                    items: items, to: dest, options: options,
                    progress: { p in
                        let now = DispatchTime.now().uptimeNanoseconds
                        let isFinal = p.completedFiles == p.totalFiles
                        if !isFinal && now &- lastTick < throttleNs { return }
                        lastTick = now
                        DispatchQueue.main.async { pc.update(p) }
                    },
                    isCancelled: { pc.isCancelled })
                DispatchQueue.main.async {
                    finished = true
                    pc.finish()
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                    conclude()
                }
            } catch CleanZipError.cancelled {
                DispatchQueue.main.async {
                    finished = true
                    pc.finish()
                    try? FileManager.default.removeItem(at: dest)   // 途中まで書いた zip を掃除
                    conclude()
                }
            } catch {
                DispatchQueue.main.async {
                    finished = true
                    pc.finish()
                    NSAlert(error: error).runModal()
                    conclude()
                }
            }
        }
    }
}
