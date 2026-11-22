import SwiftUI
import WebKit
import PhotosUI
import UniformTypeIdentifiers
import AVFoundation

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
    let cancelFlag = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private var converting = false
    private var scopedSource: URL?        // a Files pick we are reading in place
    enum ImportHow { case inPlace, move }
    private var lastProgress = -1.0

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
        case "cancelConvert": cancelFlag.pointee = 1
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
            DispatchQueue.global(qos: .userInitiated).async {
                self.importVideo(from: docs.appendingPathComponent(name), name: name, how: .inPlace)
            }
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
        var types: [UTType] = [.movie, .video, .mpeg4Movie, .quickTimeMovie, .audiovisualContent, .avi]
        for ext in ["mkv", "webm", "ts", "m2ts", "flv", "wmv", "ogv", "3gp", "vob", "mts"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
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
            self.importVideo(from: url, name: name, how: .move)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            self.importVideo(from: url, name: url.lastPathComponent, how: .inPlace)
        }
    }

    /// Opens the picked video. Files the iPhone can play are served as they are, read in
    /// place when they come from Files (no copy). Anything else (MKV, AVI, unsupported
    /// codecs) is converted next to the page first.
    private func importVideo(from source: URL, name: String, how: ImportHow) {
        if converting { return }
        let fm = FileManager.default
        if let old = scopedSource { old.stopAccessingSecurityScopedResource(); scopedSource = nil }
        onMain { self.scheme.aliases.removeAll() }
        for old in (try? fm.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: old)
        }
        let ext = source.pathExtension.isEmpty ? "mov" : source.pathExtension.lowercased()
        let working: URL
        switch how {
        case .inPlace:
            if source.startAccessingSecurityScopedResource() { scopedSource = source }
            // Makes sure an iCloud file is downloaded before it is read.
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordError) { _ in }
            guard fm.isReadableFile(atPath: source.path) else {
                return fail("לא הצלחתי לקרוא את הקובץ. \(coordError?.localizedDescription ?? "")")
            }
            working = source
        case .move:
            let dest = mediaDir.appendingPathComponent("v-\(UUID().uuidString.prefix(8)).\(ext)")
            do {
                do { try fm.moveItem(at: source, to: dest) } catch { try fm.copyItem(at: source, to: dest) }
            } catch {
                return fail("לא הצלחתי להעתיק את הסרטון: \(error.localizedDescription)")
            }
            working = dest
        }
        print("KADR-NATIVE: imported \(name)")
        Task {
            let native = ["mp4", "mov", "m4v", "3gp"].contains(ext)
            let playable = native ? ((try? await AVURLAsset(url: working).load(.isPlayable)) ?? false) : false
            if playable {
                self.openInPage(working, name: name, subs: [])
            } else {
                self.convert(working, name: name, deleteSource: how == .move, flags: 0)
            }
        }
    }

    private func convert(_ src: URL, name: String, deleteSource: Bool, flags: Int32,
                         subsFromFirstPass: [[String: String]]? = nil) {
        converting = true
        cancelFlag.pointee = 0
        lastProgress = -1
        let out = mediaDir.appendingPathComponent("c-\(UUID().uuidString.prefix(8)).mp4")
        let subsDir = mediaDir.appendingPathComponent("subs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: subsDir, withIntermediateDirectories: true)
        print("KADR-NATIVE: converting \(name) flags=\(flags)")
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
            self.webView?.evaluateJavaScript("window.kadrNativeConvert && window.kadrNativeConvert('start',0,0)")
        }
        let background = UIApplication.shared.beginBackgroundTask(withName: "kadr-convert")
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            var err = [CChar](repeating: 0, count: 512)
            let rc = kadr_convert(src.path, out.path, subsDir.path, flags, self.cancelFlag, { frac, mode, ctx in
                guard let ctx = ctx else { return }
                Unmanaged<PlayerController>.fromOpaque(ctx).takeUnretainedValue().reportProgress(frac, mode: Int(mode))
            }, ctx, &err, Int32(err.count))
            let message = String(cString: err)
            print("KADR-NATIVE: convert rc=\(rc) in \(String(format: "%.2f", Date().timeIntervalSince(started)))s \(message)")
            let subs = subsFromFirstPass ?? self.readSubs(subsDir)

            // Copied audio (Opus, FLAC, AC-3…) is checked on this device; if it can't play,
            // convert once more with the audio re-encoded.
            var audioOK = true
            if rc == 0 && (flags & KADR_FORCE_AUDIO) == 0 {
                let sem = DispatchSemaphore(value: 0)
                Task {
                    if let track = try? await AVURLAsset(url: out).loadTracks(withMediaType: .audio).first {
                        audioOK = (try? await track.load(.isPlayable)) ?? false
                    }
                    sem.signal()
                }
                sem.wait()
                print("KADR-NATIVE: audio playable \(audioOK)")
            }

            DispatchQueue.main.async {
                self.converting = false
                UIApplication.shared.isIdleTimerDisabled = false
                UIApplication.shared.endBackgroundTask(background)
                if rc == 0 && !audioOK {
                    try? FileManager.default.removeItem(at: out)
                    self.convert(src, name: name, deleteSource: deleteSource, flags: KADR_FORCE_AUDIO,
                                 subsFromFirstPass: subs)
                    return
                }
                if deleteSource { try? FileManager.default.removeItem(at: src) }
                self.webView?.evaluateJavaScript("window.kadrNativeConvert && window.kadrNativeConvert('end',1,0)")
                if rc == 0 {
                    self.openInPage(out, name: name, subs: subs)
                } else {
                    try? FileManager.default.removeItem(at: out)
                    if rc == KADR_CANCELLED {
                        self.webView?.evaluateJavaScript("window.kadrNativeCancelled && window.kadrNativeCancelled()")
                    } else {
                        self.fail(message.isEmpty ? "ההמרה נכשלה." : message)
                    }
                }
            }
        }
    }

    private func reportProgress(_ frac: Double, mode: Int) {
        if frac - lastProgress < 0.01 && frac < 1 && frac > 0 { return }
        lastProgress = frac
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.kadrNativeConvert && window.kadrNativeConvert('progress',\(frac),\(mode))")
        }
    }

    private func readSubs(_ dir: URL) -> [[String: String]] {
        guard let index = try? String(contentsOf: dir.appendingPathComponent("subs.tsv"), encoding: .utf8) else { return [] }
        var out: [[String: String]] = []
        for line in index.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 1, !parts[0].isEmpty else { continue }
            let url = dir.appendingPathComponent(parts[0])
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)),
                  !text.isEmpty else { continue }
            out.append([
                "file": parts[0],
                "lang": parts.count > 1 ? parts[1] : "",
                "title": parts.count > 2 ? parts[2] : "",
                "text": text,
            ])
        }
        return out
    }

    private func openInPage(_ file: URL, name: String, subs: [[String: String]]) {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        var served = file.lastPathComponent
        if file.deletingLastPathComponent().standardizedFileURL.path != mediaDir.standardizedFileURL.path {
            let ext = file.pathExtension.isEmpty ? "mov" : file.pathExtension.lowercased()
            served = "x-\(UUID().uuidString.prefix(8)).\(ext)"
            let alias = served
            onMain { self.scheme.aliases[alias] = file }
        }
        let info: [String: Any] = [
            "url": "\(LocalSchemeHandler.scheme)://app/media/\(served)",
            "name": name,
            "size": size,
            "subs": subs,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: info),
              let json = String(data: data, encoding: .utf8) else { return }
        print("KADR-NATIVE: open \(served) (\(size) bytes, \(subs.count) subtitle tracks)")
        DispatchQueue.main.async {
            self.webView?.evaluateJavaScript("window.kadrNativeOpen(\(json))")
        }
        // The exact frame rate makes the frame counter right from the first frame.
        Task {
            let asset = AVURLAsset(url: file)
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let fps = try? await track.load(.nominalFrameRate), fps > 0 else { return }
            print("KADR-NATIVE: frame rate \(fps)")
            DispatchQueue.main.async {
                self.webView?.evaluateJavaScript("window.kadrNativeFps && window.kadrNativeFps(\(fps))")
            }
        }
    }

    /// Runs `body` on the main thread and waits, without deadlocking when already there.
    private func onMain(_ body: () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.sync(execute: body) }
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
    var aliases: [String: URL] = [:]                 // media/<name> served from elsewhere (main thread)
    private var live = Set<ObjectIdentifier>()       // touched on the main thread only
    private let io = DispatchQueue(label: "kadr.scheme.io", qos: .userInitiated)

    init(root: URL) { self.root = root.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        live.insert(id)
        guard let url = task.request.url else { return finish(task, id, status: 400) }

        var path = url.path
        if path.isEmpty || path == "/" { path = "/index.html" }
        var file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        if path.hasPrefix("/media/"), let target = aliases[String(path.dropFirst(7))] { file = target }
        guard file.path.hasPrefix(root.path) || aliases.values.contains(file),
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
