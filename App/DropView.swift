import SwiftUI
import UniformTypeIdentifiers

struct DropView: View {
    @State private var hovering = false
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(hovering ? Color.accentColor : .secondary)
            VStack(spacing: 8) {
                Image(systemName: "doc.zipper").font(.system(size: 40))
                Text("ここにファイル / フォルダをドロップ")
                Text("__MACOSX・.DS_Store を除いたクリーンZIPを作成")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 360, height: 220).padding()
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            load(providers) { urls in
                guard !urls.isEmpty else { return }
                ZipController.shared.begin(with: urls)
            }
            return true
        }
    }

    private func load(_ providers: [NSItemProvider], done: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for p in providers {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { done(urls) }
    }
}
