import AppKit
import UniformTypeIdentifiers
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
        let defaultEnc = NeatZipSettings.defaultEncryption
        var password: String? = nil
        var encryption: ZipEncryption = defaultEnc.zipEncryption

        // 「毎回確認」設定 or 暗号化にパスワードが要る場合のみダイアログを出す。
        // 無暗号＋確認OFF なら即作成（右クリックの最短経路）。
        if NeatZipSettings.promptEachTime || defaultEnc.needsPassword {
            let r = promptOptions(default: defaultEnc)
            guard r.proceed else {
                if quitWhenDone { NSApp.terminate(nil) }   // ダイアログでキャンセル → 残らず終了
                return
            }
            password = r.password
            encryption = r.encryption
        }

        guard let dest = resolveDestination(for: items) else {
            if quitWhenDone { NSApp.terminate(nil) }   // 保存先未決（空 / ask でキャンセル）
            return
        }
        run(items: items, to: dest,
            options: CleanZipOptions(password: password, encryption: encryption,
                                     compressionLevel: NeatZipSettings.compressionLevel),
            quitWhenDone: quitWhenDone)
    }

    private func promptOptions(default defaultEnc: DefaultEncryption)
        -> (password: String?, encryption: ZipEncryption, proceed: Bool) {
        let alert = NSAlert()
        alert.messageText = String(localized: "dialog.title")
        alert.informativeText = String(localized: "dialog.passwordHint")
        alert.addButton(withTitle: String(localized: "common.create"))
        alert.addButton(withTitle: String(localized: "common.cancel"))

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 260, height: 24))
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        popup.addItems(withTitles: [String(localized: "enc.zipcrypto.long"),
                                    String(localized: "enc.aes.long")])
        popup.selectItem(at: defaultEnc == .aes256 ? 1 : 0)   // 設定の既定方式を初期選択
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        box.addSubview(field); box.addSubview(popup)
        alert.accessoryView = box

        let proceed = alert.runModal() == .alertFirstButtonReturn
        let pw = field.stringValue.isEmpty ? nil : field.stringValue
        let enc: ZipEncryption = pw == nil ? .none
            : (popup.indexOfSelectedItem == 1 ? .aes256 : .zipCrypto)
        return (pw, enc, proceed)
    }

    // MARK: - 出力先の解決（設定の OutputLocation に従う）

    private func resolveDestination(for items: [URL]) -> URL? {
        #if MAS
        // サンドボックスでは powerbox（保存パネル）経由でしか出力先に書き込めない。
        // 「隣に出す」「固定フォルダ」はサンドボックス外のパスで不可なので常に保存パネルにする（DESIGN §12）。
        return askDestination(for: items)
        #else
        switch NeatZipSettings.outputLocation {
        case .besideSource:
            return CleanZip.suggestedDestination(for: items)
        case .fixedFolder:
            if let folder = NeatZipSettings.fixedFolderPath {
                return uniqueDestination(in: URL(fileURLWithPath: folder, isDirectory: true), for: items)
            }
            return CleanZip.suggestedDestination(for: items)   // 未設定なら隣にフォールバック
        case .ask:
            return askDestination(for: items)
        }
        #endif
    }

    private func baseName(for items: [URL]) -> String {
        items.count == 1 ? items[0].deletingPathExtension().lastPathComponent : "Archive"
    }

    #if !MAS
    // 「隣に出す」「固定フォルダ」用の重複回避。MAS（保存パネル固定）では使わない。
    private func uniqueDestination(in folder: URL, for items: [URL]) -> URL {
        let fm = FileManager.default
        let base = baseName(for: items)
        var url = folder.appendingPathComponent(base).appendingPathExtension("zip")
        var i = 2
        while fm.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(i)").appendingPathExtension("zip")
            i += 1
        }
        return url
    }
    #endif

    private func askDestination(for items: [URL]) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        // 「元の隣」を初期値に: 元フォルダで開き <name>.zip を提案（重複は連番）。既定の「保存」で
        // そのまま隣に出せる。MAS（サンドボックス）でも保存パネルは powerbox（別プロセス）なので
        // 初期位置の指定は非束縛、確定時にその場所への書き込み権が付与される（DESIGN §12）。
        if let suggested = CleanZip.suggestedDestination(for: items) {
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.nameFieldStringValue = suggested.lastPathComponent
        } else {
            panel.nameFieldStringValue = baseName(for: items) + ".zip"
        }
        return panel.runModal() == .OK ? panel.url : nil
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
                let result = try CleanZip.make(
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
                    // 読めず除外したファイルがあれば、Finder 表示の前にまとめて知らせる。
                    if !result.skipped.isEmpty { self.reportSkipped(result.skipped) }
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
                    // 致命的エラーでも途中まで書いた壊れた zip を残さない。
                    try? FileManager.default.removeItem(at: dest)
                    NSAlert(error: error).runModal()
                    conclude()
                }
            }
        }
    }

    /// 読み込めず除外したファイルを1枚のアラートにまとめて提示する（先頭 maxShown 件＋「ほか N 件」）。
    private func reportSkipped(_ skipped: [SkippedItem]) {
        let maxShown = 10
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "partial.title")
        var body = String(format: String(localized: "partial.body"), skipped.count)
        body += "\n\n" + skipped.prefix(maxShown).map { "• \($0.path)" }.joined(separator: "\n")
        if skipped.count > maxShown {
            body += "\n" + String(format: String(localized: "partial.more"), skipped.count - maxShown)
        }
        alert.informativeText = body
        alert.runModal()   // ボタン未追加なら system 既定の「OK」が出る
    }
}
