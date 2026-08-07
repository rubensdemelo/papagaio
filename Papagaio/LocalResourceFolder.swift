import AppKit
import Combine
import Foundation

struct LocalResourceFolderSelection: Equatable, Sendable {
    let path: String

    var displayName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

enum LocalResourceFolderError: Error, Equatable, Sendable {
    case accessLost(path: String)
    case missing(path: String)
    case notDirectory(path: String)
    case notReadable(path: String)
    case bookmarkSaveFailed(path: String)
    case bookmarkRefreshFailed(path: String)
}

enum LocalResourceFolderState: Equatable, Sendable {
    case empty
    case selected(LocalResourceFolderSelection)
    case error(LocalResourceFolderError)
}

struct LocalResourceFolderBookmarkStore {
    static let defaultKey = "localResourceFolder.securityScopedBookmark"

    let defaults: UserDefaults
    let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = LocalResourceFolderBookmarkStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> Data? {
        defaults.data(forKey: key)
    }

    func save(_ bookmark: Data) {
        defaults.set(bookmark, forKey: key)
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}

struct LocalResourceFolderValidator {
    func validate(url: URL) -> Result<LocalResourceFolderSelection, LocalResourceFolderError> {
        let standardizedURL = url.standardizedFileURL
        let path = standardizedURL.path

        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.missing(path: path))
        }
        guard (try? standardizedURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return .failure(.notDirectory(path: path))
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            return .failure(.notReadable(path: path))
        }

        return .success(LocalResourceFolderSelection(path: path))
    }
}

@MainActor
final class LocalResourceFolderController: ObservableObject {
    @Published private(set) var state: LocalResourceFolderState = .empty

    private let bookmarkStore: LocalResourceFolderBookmarkStore
    private let validator: LocalResourceFolderValidator
    private var accessedURL: URL?

    init(
        bookmarkStore: LocalResourceFolderBookmarkStore = LocalResourceFolderBookmarkStore(),
        validator: LocalResourceFolderValidator = LocalResourceFolderValidator()
    ) {
        self.bookmarkStore = bookmarkStore
        self.validator = validator
        restore()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose Resource Folder"
        panel.message = "Choose a local folder containing manuals and support resources."
        panel.prompt = "Choose Folder"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        select(url: url)
    }

    func clearSelection() {
        stopAccessingCurrentFolder()
        bookmarkStore.clear()
        state = .empty
    }

    private func restore() {
        guard let bookmark = bookmarkStore.load() else {
            state = .empty
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            beginAccessing(url)

            switch validator.validate(url: url) {
            case .success(let selection):
                if isStale {
                    do {
                        bookmarkStore.save(try makeBookmark(for: url))
                    } catch {
                        stopAccessingCurrentFolder()
                        state = .error(.bookmarkRefreshFailed(path: selection.path))
                        return
                    }
                }
                state = .selected(selection)
            case .failure(let error):
                stopAccessingCurrentFolder()
                state = .error(error)
            }
        } catch {
            state = .error(.accessLost(path: "The previously selected folder"))
        }
    }

    private func select(url: URL) {
        stopAccessingCurrentFolder()
        beginAccessing(url)

        switch validator.validate(url: url) {
        case .success(let selection):
            do {
                bookmarkStore.save(try makeBookmark(for: url))
                state = .selected(selection)
            } catch {
                stopAccessingCurrentFolder()
                state = .error(.bookmarkSaveFailed(path: selection.path))
            }
        case .failure(let error):
            stopAccessingCurrentFolder()
            state = .error(error)
        }
    }

    private func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    private func beginAccessing(_ url: URL) {
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }
    }

    private func stopAccessingCurrentFolder() {
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
    }
}

extension LocalResourceFolderError {
    var title: String {
        switch self {
        case .accessLost:
            "Folder access is no longer available"
        case .missing:
            "Folder not found"
        case .notDirectory:
            "The selected location is not a folder"
        case .notReadable:
            "Folder cannot be read"
        case .bookmarkSaveFailed, .bookmarkRefreshFailed:
            "Folder access could not be saved"
        }
    }

    var detail: String {
        switch self {
        case .accessLost:
            "Choose the folder again to give Papagaio access under macOS sandbox rules."
        case .missing:
            "The folder may have been moved or disconnected. Choose it again."
        case .notDirectory:
            "Choose a folder containing manuals and support resources."
        case .notReadable:
            "Papagaio cannot read this location. Check its permissions or choose another folder."
        case .bookmarkSaveFailed, .bookmarkRefreshFailed:
            "Choose the folder again. Papagaio keeps only its access permission, not the folder contents."
        }
    }

    var path: String {
        switch self {
        case .accessLost(let path),
             .missing(let path),
             .notDirectory(let path),
             .notReadable(let path),
             .bookmarkSaveFailed(let path),
             .bookmarkRefreshFailed(let path):
            path
        }
    }
}

extension LocalResourceFolderState {
    var folderSelection: LocalResourceFolderSelection? {
        guard case .selected(let selection) = self else {
            return nil
        }
        return selection
    }
}
