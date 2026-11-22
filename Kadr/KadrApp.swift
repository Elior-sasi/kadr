import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers

@main
struct KadrApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.black.ignoresSafeArea()
                PlayerWebView()
            }
            .preferredColorScheme(.dark)
        }
    }
}

/// Hosts the player page. The page and the picked video are both served from the
/// app's own `kadr://app/` origin, so the video plays natively (with byte ranges)
/// and canvas reads (frame snapshot, cut search) stay same-origin.
struct PlayerWebView: UIViewRepresentable {
    func makeCoordinator() -> PlayerController { PlayerController() }

    func makeUIView(context: Context) -> WKWebView {
        let controller = context.coordinator
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.setURLSchemeHandler(controller.scheme, forURLScheme: LocalSchemeHandler.scheme)
        config.userContentController.add(controller, name: "kadr")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.allowsLinkPreview = false
        webView.navigationDelegate = controller
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        controller.webView = webView

        webView.load(URLRequest(url: URL(string: "\(LocalSchemeHandler.scheme)://app/index.html")!))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

final class PlayerController: NSObject, WKScriptMessageHandler, WKNavigationDelegate,
                              UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    weak var webView: WKWebView?
    let wwwDir: URL
    let mediaDir: URL
    let scheme: LocalSchemeHandler

    override init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        wwwDir = caches.appendingPathComponent("www", isDirectory: true)
        mediaDir = wwwDir.appendingPathComponent("media", isDirectory: true)
        scheme = LocalSchemeHandler(root: wwwDir)
        super.init()
        preparePage()
    }

    private func preparePage() {
        let fm = FileManager.default
        try? fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        if let src = Bundle.main.url(forResource: "index", withExtension: "html") {
            let dst = wwwDir.appendingPathComponent("index.html")
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }

    // MARK: messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "pickVideo": presentSourceMenu()
        case "log": print("KADR-JS: \(body["text"] ?? "")")
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Simulator self-test: `-KadrTestVideo test.mp4` opens Documents/test.mp4 and runs the page's checks.
        if let name = UserDefaults.standard.string(forKey: "KadrTestVideo") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            print("KADR-NATIVE: self-test with \(name)")
            webView.evaluateJavaScript("window.__kadrSelfTest && window.__kadrSelfTest()")
            importVideo(from: docs.appendingPathComponent(name), name: name)
        }
    }

    // MARK: picking

    private func topController() -> UIViewController? {
        var top = webView?.window?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    private func presentSourceMenu() {
        guard let top = topController() else { return }
        let sheet = UIAlertController(title: "פתיחת וידאו", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "ספריית התמונות", style: .default) { _ in self.presentPhotos() })
        sheet.addAction(UIAlertAction(title: "קבצים", style: .default) { _ in self.presentFiles() })
        sheet.addAction(UIAlertAction(title: "ביטול", style: .cancel))
        if let pop = sheet.popoverPresentationController, let view = webView {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }

    private func presentPhotos() {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current   // no re-encoding
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        topController()?.present(picker, animated: true)
    }

    private func presentFiles() {
        let types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        topController()?.present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider else { return }
        let type = provider.registeredTypeIdentifiers
            .first { UTType($0)?.conforms(to: .movie) == true } ?? UTType.movie.identifier
        let suggested = provider.suggestedName ?? "video"
        setBusy(true)
        provider.loadFileRepresentation(forTypeIdentifier: type) { url, error in
            // The temporary file is deleted when this block returns, so copy it now.
            guard let url = url else {
                self.fail("לא הצלחתי לקרוא את הסרטון מהתמונות. \(error?.localizedDescription ?? "")")
                return
            }
            let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
            let name = (suggested as NSString).pathExtension.isEmpty ? "\(suggested).\(ext)" : suggested
            self.importVideo(from: url, name: name)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        setBusy(true)
        importVideo(from: url, name: url.lastPathComponent)
    }

    /// Copies the picked video next to the page and hands its URL to the player.
    private func importVideo(from source: URL, name: String) {
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            for old in (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: old)
            }
            let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
            let fileName = "v-\(UUID().uuidString.prefix(8)).\(ext)"
            let dest = mediaDir.appendingPathComponent(fileName)
            try fm.copyItem(at: source, to: dest)
            let size = (try? fm.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            let info: [String: Any] = [
                "url": "\(LocalSchemeHandler.scheme)://app/media/\(fileName)",
                "name": name,
                "size": size,
            ]
            let json = String(data: try JSONSerialization.data(withJSONObject: info), encoding: .utf8) ?? "{}"
            print("KADR-NATIVE: imported \(name) (\(size) bytes)")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("window.kadrNativeOpen(\(json))")
            }
        } catch {
            fail("לא הצלחתי להעתיק את הסרטון: \(error.localizedDescription)")
        }
    }

    private func setBusy(_ busy: Bool) {
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.kadrNativeBusy && window.kadrNativeBusy(\(busy))")
        }
    }

    private func fail(_ text: String) {
        print("KADR-NATIVE: error \(text)")
        let json = String(data: (try? JSONSerialization.data(withJSONObject: [text])) ?? Data(), encoding: .utf8) ?? "[\"\"]"
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.kadrNativeError && window.kadrNativeError(\(json)[0])")
        }
    }
}

/// Serves files under `root` at kadr://app/…, with HTTP byte-range support so
/// WebKit's media player can seek through large videos.
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "kadr"
    let root: URL
    private var live = Set<ObjectIdentifier>()       // touched on the main thread only
    private let io = DispatchQueue(label: "kadr.scheme.io", qos: .userInitiated)

    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        guard let url = task.request.url else { return finish(task, id, status: 400) }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        else { return finish(task, id, status: 404) }

        var start: Int64 = 0
        var end: Int64 = max(0, size - 1)
        var partial = false
        if let header = task.request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") {
            let spec = header.dropFirst(6).split(separator: ",").first ?? ""
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { String($0) }
            if parts.count == 2 {
                if parts[0].isEmpty, let suffix = Int64(parts[1]) {          // bytes=-500
                    start = max(0, size - suffix)
                } else if let a = Int64(parts[0]) {
                    start = a
                    if let b = Int64(parts[1]) { end = min(b, size - 1) }
                }
                partial = true
            }
        }
        if size == 0 { start = 0; end = -1; partial = false }
        if start > end && size > 0 {
            let resp = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Range": "bytes */\(size)"])!
            task.didReceive(resp)
            task.didFinish()
            live.remove(id)
            return
        }
        let length = end - start + 1
        var headers = [
            "Content-Type": Self.mime(file.pathExtension),
            "Content-Length": "\(max(0, length))",
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
        ]
        if partial { headers["Content-Range"] = "bytes \(start)-\(end)/\(size)" }
        let response = HTTPURLResponse(url: url, statusCode: partial ? 206 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!

        io.async {
            guard let handle = try? FileHandle(forReadingFrom: file) else {
                DispatchQueue.main.async { self.finish(task, id, status: 500) }
                return
            }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(start))
            guard self.onMain(id, { task.didReceive(response) }) else { return }
            var remaining = max(0, length)
            while remaining > 0 {
                let chunk = handle.readData(ofLength: Int(min(remaining, 512 * 1024)))
                if chunk.isEmpty { break }
                remaining -= Int64(chunk.count)
                guard self.onMain(id, { task.didReceive(chunk) }) else { return }
            }
            _ = self.onMain(id, { task.didFinish(); self.live.remove(id) })
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live.remove(ObjectIdentifier(task))
    }

    /// Runs `body` on the main thread only if the task was not stopped; calling a
    /// stopped task raises an exception, so the check and the call happen together.
    private func onMain(_ id: ObjectIdentifier, _ body: @escaping () -> Void) -> Bool {
        var ok = false
        DispatchQueue.main.sync {
            if self.live.contains(id) { body(); ok = true }
        }
        return ok
    }

    private func finish(_ task: WKURLSchemeTask, _ id: ObjectIdentifier, status: Int) {
        guard live.contains(id) else { return }
        let resp = HTTPURLResponse(url: task.request.url ?? URL(string: "\(Self.scheme)://app/")!,
                                   statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
        task.didReceive(resp)
        task.didFinish()
        live.remove(id)
    }

    static func mime(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "mp4": return "video/mp4"
        case "m4v": return "video/x-m4v"
        case "mov", "qt": return "video/quicktime"
        case "3gp": return "video/3gpp"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        default: return "application/octet-stream"
        }
    }
}
