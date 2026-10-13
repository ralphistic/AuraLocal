import Flutter
import UIKit
import UniformTypeIdentifiers

/// Opens files in place instead of copying them into the application's sandbox.
/// Bookmarks are best-effort: iOS may require the user to grant access again.
final class AuraFileReferences: NSObject, UIDocumentPickerDelegate {
    private let channel: FlutterMethodChannel
    private var pending: FlutterResult?
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
            default: result(FlutterMethodNotImplemented)
            }
        }
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
        var stored = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        var picked: [[String: String]] = []
        for url in urls {
            // Some local Files URLs are readable without a security-scope token.
            // A false return does not mean the user cancelled selection.
            _ = url.startAccessingSecurityScopedResource()
            let path = url.path
            granted[path] = url
            do {
                let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                stored[url.lastPathComponent + "|" + path] = bookmark.base64EncodedString()
                picked.append(["path": path, "name": url.lastPathComponent])
            } catch {
                // Access is still valid for this session, but may not survive relaunch.
                picked.append(["path": path, "name": url.lastPathComponent])
            }
        }
        UserDefaults.standard.set(stored, forKey: storageKey)
        pending?(picked)
        pending = nil
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
