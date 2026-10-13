import Flutter
import UIKit
import UniformTypeIdentifiers

/// Opens files in place instead of copying them into the application's sandbox.
/// Bookmarks are best-effort: iOS may require the user to grant access again.
final class AuraFileReferences: NSObject, UIDocumentPickerDelegate {
    private let channel: FlutterMethodChannel
    private var pending: FlutterResult?
    private var documentInteraction: UIDocumentInteractionController?
    private var granted: [String: URL] = [:]
    private let storageKey = "AuraLocal.securityScopedAudioBookmarks"

    init(messenger: FlutterBinaryMessenger) {
        channel = FlutterMethodChannel(name: "auralocal/file_references", binaryMessenger: messenger)
        super.init()
        channel.setMethodCallHandler { [weak self] call, result in
            guard let self = self else { result(FlutterError(code: "CLOSED", message: nil, details: nil)); return }
            switch call.method {
            case "pickInPlace": self.presentPicker(result)
            case "restoreReferences": result(self.restore())
            case "openOriginalLocation":
                guard let path = call.arguments as? String else {
                    result(FlutterError(code: "INVALID_PATH", message: "Missing file path", details: nil))
                    return
                }
                self.openOriginalLocation(path, result: result)
            default: result(FlutterMethodNotImplemented)
            }
        }
    }

    private func openOriginalLocation(_ path: String, result: @escaping FlutterResult) {
        // iOS does not expose a public API to reveal an arbitrary file in its
        // original Files folder. Show the system document interaction options
        // for its original security-scoped URL instead of a misleading path copy.
        let url = granted[path] ?? URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            result(FlutterError(code: "FILE_UNAVAILABLE", message: "Original file is no longer accessible. Relink it from Files.", details: nil))
            return
        }
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            result(FlutterError(code: "NO_WINDOW", message: "Cannot open document options", details: nil))
            return
        }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        let interaction = UIDocumentInteractionController(url: url)
        documentInteraction = interaction
        let shown = interaction.presentOptionsMenu(from: CGRect(x: presenter.view.bounds.midX,
            y: presenter.view.bounds.midY, width: 1, height: 1), in: presenter.view, animated: true)
        if !shown { documentInteraction = nil }
        result(shown)
    }

    private func presentPicker(_ result: @escaping FlutterResult) {
        guard pending == nil else {
            result(FlutterError(code: "BUSY", message: "A picker is already open", details: nil))
            return
        }
        let picker: UIDocumentPickerViewController
        if #available(iOS 14.0, *) {
            let types: [UTType] = ["flac", "mp3", "wav", "m4a", "aac"]
                .compactMap { UTType(filenameExtension: $0) }
            picker = UIDocumentPickerViewController(
                forOpeningContentTypes: types.isEmpty ? [.audio] : types, asCopy: false)
        } else {
            picker = UIDocumentPickerViewController(documentTypes: ["public.audio"], in: .open)
        }
        picker.allowsMultipleSelection = true
        picker.delegate = self
        guard let root = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            result(FlutterError(code: "NO_WINDOW", message: "Cannot present Files", details: nil))
            return
        }
        pending = result
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(picker, animated: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pending?([])
        pending = nil
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Do not synchronously generate provider bookmarks in the picker
        // callback. iCloud/third-party providers can block the UI for seconds.
        let picked = urls.map { ["path": $0.path, "name": $0.lastPathComponent] }
        for url in urls {
            _ = url.startAccessingSecurityScopedResource()
            granted[url.path] = url
        }
        let completion = pending
        pending = nil
        controller.dismiss(animated: true) {
            completion?(picked)
        }
        // Persist bookmarks away from the UI thread, without holding up import.
        DispatchQueue.global(qos: .utility).async { [storageKey] in
            var stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
            for url in urls {
                if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    stored[url.lastPathComponent + "|" + url.path] = bookmark.base64EncodedString()
                }
            }
            UserDefaults.standard.set(stored, forKey: storageKey)
        }
    }

    private func restore() -> [[String: String]] {
        let stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        var recovered: [[String: String]] = []
        for (key, encoded) in stored {
            guard let data = Data(base64Encoded: encoded) else { continue }
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else { continue }
            _ = url.startAccessingSecurityScopedResource()
            granted[url.path] = url
            if FileManager.default.fileExists(atPath: url.path) {
                recovered.append(["path": url.path, "name": url.lastPathComponent,
                                  "previousKey": key])
            }
        }
        return recovered
    }

    deinit {
        for url in granted.values { url.stopAccessingSecurityScopedResource() }
    }
}
