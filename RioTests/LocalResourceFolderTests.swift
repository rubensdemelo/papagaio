import Foundation
import XCTest

final class LocalResourceFolderTests: XCTestCase {
    func testValidatorAcceptsReadableDirectoryWithoutInspectingContents() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = LocalResourceFolderValidator().validate(url: directory)

        XCTAssertEqual(
            result,
            .success(
                LocalResourceFolderSelection(path: directory.standardizedFileURL.path)
            )
        )
    }

    func testValidatorReportsMissingDirectory() {
        let url = URL(fileURLWithPath: "/tmp/rio-resource-folder-that-does-not-exist")

        let result = LocalResourceFolderValidator().validate(url: url)

        XCTAssertEqual(result, .failure(.missing(path: url.standardizedFileURL.path)))
    }

    func testValidatorRejectsAFileAsAResourceFolder() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("rio-resource-file-(UUID().uuidString)")
        try Data("synthetic fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = LocalResourceFolderValidator().validate(url: file)

        XCTAssertEqual(result, .failure(.notDirectory(path: file.standardizedFileURL.path)))
    }

    @MainActor
    func testControllerStartsEmptyWithoutAPersistedBookmark() {
        let defaults = makeDefaults()
        let controller = LocalResourceFolderController(
            bookmarkStore: LocalResourceFolderBookmarkStore(
                defaults: defaults,
                key: "test.bookmark"
            )
        )

        XCTAssertEqual(controller.state, .empty)
    }

    @MainActor
    func testControllerReportsAnInvalidPersistedBookmarkAsAnAccessError() {
        let defaults = makeDefaults()
        defaults.set(Data("not a bookmark".utf8), forKey: "test.bookmark")

        let controller = LocalResourceFolderController(
            bookmarkStore: LocalResourceFolderBookmarkStore(
                defaults: defaults,
                key: "test.bookmark"
            )
        )

        XCTAssertEqual(
            controller.state,
            .error(.accessLost(path: "The previously selected folder"))
        )
    }

    func testErrorPresentationExplainsWhatToDoAndDoesNotSuggestIngestion() {
        let error = LocalResourceFolderError.missing(path: "/Users/example/Manuals")

        XCTAssertEqual(error.title, "Folder not found")
        XCTAssertTrue(error.detail.contains("Choose it again"))
        XCTAssertFalse(error.detail.localizedCaseInsensitiveContains("search"))
        XCTAssertFalse(error.detail.localizedCaseInsensitiveContains("upload"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rio-resource-folder-(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "RioTests.LocalResourceFolder.(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
