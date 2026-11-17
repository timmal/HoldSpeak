import XCTest
@testable import HoldSpeakCore

/// Only a complete model folder counts as downloaded, and a finished download never
/// replaces a complete folder with a partial one. Fake folders live in a temp dir.
final class ModelFolderTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("ModelFolderTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    /// A Whisper folder holding `files` (relative paths), each a few bytes.
    @discardableResult
    private func whisperFolder(_ name: String, files: [String] = WhisperSupport.requiredFiles) throws -> URL {
        let dir = root.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            let url = dir.appendingPathComponent(file)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            XCTAssertTrue(fm.createFile(atPath: url.path, contents: Data(name.utf8)))
        }
        return dir
    }

    private func marker(in dir: URL) throws -> String {
        let first = dir.appendingPathComponent(WhisperSupport.requiredFiles[0])
        return try String(contentsOf: first, encoding: .utf8)
    }

    // MARK: completeness

    /// What `WhisperKit.loadModels` opens (WhisperKit 0.18.0, Core/WhisperKit.swift):
    /// MelSpectrogram, AudioEncoder and TextDecoder, each a compiled Core ML bundle.
    func test_requiredFiles_coverTheThreeBundlesWhisperKitLoads() {
        for bundle in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            for inner in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                XCTAssertTrue(WhisperSupport.requiredFiles.contains("\(bundle).mlmodelc/\(inner)"), "\(bundle) \(inner)")
            }
        }
    }

    func test_completeFolder_isAModel() throws {
        let dir = try whisperFolder("complete")
        XCTAssertTrue(WhisperSupport.modelExists(in: dir))
    }

    func test_folderMissingAnyOneRequiredFile_isNotAModel() throws {
        for (i, missing) in WhisperSupport.requiredFiles.enumerated() {
            let dir = try whisperFolder("missing-\(i)", files: WhisperSupport.requiredFiles.filter { $0 != missing })
            XCTAssertFalse(WhisperSupport.modelExists(in: dir), "missing \(missing)")
        }
    }

    func test_emptyOrAbsentFolder_isNotAModel() throws {
        let empty = try whisperFolder("empty", files: [])
        XCTAssertFalse(WhisperSupport.modelExists(in: empty))
        XCTAssertFalse(WhisperSupport.modelExists(in: root.appendingPathComponent("absent")))
    }

    // MARK: locating

    func test_locate_managedCompleteWinsOverExternalPartial() throws {
        let managed = try whisperFolder("managed")
        let external = try whisperFolder("external", files: Array(WhisperSupport.requiredFiles.dropLast()))
        XCTAssertEqual(ModelFolders.firstComplete([managed, external], isComplete: { WhisperSupport.modelExists(in: $0) }),
                       managed)
        // Order is the caller's: HoldSpeak's own folder first.
        XCTAssertEqual(ModelFolders.firstComplete([external, managed], isComplete: { WhisperSupport.modelExists(in: $0) }),
                       managed)
    }

    func test_locate_externalPartialOnly_isNotFound() throws {
        let external = try whisperFolder("external", files: Array(WhisperSupport.requiredFiles.prefix(2)))
        let managedAbsent = root.appendingPathComponent("managed")
        XCTAssertNil(ModelFolders.firstComplete([managedAbsent, external], isComplete: { WhisperSupport.modelExists(in: $0) }))
    }

    func test_locate_managedPartial_fallsThroughToCompleteExternal() throws {
        let managed = try whisperFolder("managed", files: [WhisperSupport.requiredFiles[0]])
        let external = try whisperFolder("external")
        XCTAssertEqual(ModelFolders.firstComplete([managed, external], isComplete: { WhisperSupport.modelExists(in: $0) }),
                       external)
    }

    // MARK: installing a finished download

    private func install(_ downloaded: URL, at destination: URL) throws -> URL {
        try ModelFolders.install(downloaded, at: destination, isComplete: { WhisperSupport.modelExists(in: $0) })
    }

    func test_install_completeDownload_movesIntoAnEmptyPlace() throws {
        let downloaded = try whisperFolder("cache")
        let destination = root.appendingPathComponent("models/turbo")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        XCTAssertEqual(try install(downloaded, at: destination), destination)
        XCTAssertTrue(WhisperSupport.modelExists(in: destination))
        XCTAssertFalse(fm.fileExists(atPath: downloaded.path))
    }

    func test_install_completeDownload_replacesAPartialDestination() throws {
        let downloaded = try whisperFolder("cache")
        let destination = try whisperFolder("dst", files: [WhisperSupport.requiredFiles[0]])

        XCTAssertEqual(try install(downloaded, at: destination), destination)
        XCTAssertTrue(WhisperSupport.modelExists(in: destination))
        XCTAssertEqual(try marker(in: destination), "cache")
        // The replaced folder isn't left behind.
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: root.path).sorted(), ["dst"])
    }

    func test_install_partialDownload_keepsACompleteDestination() throws {
        let downloaded = try whisperFolder("cache", files: Array(WhisperSupport.requiredFiles.suffix(3)))
        let destination = try whisperFolder("dst")

        XCTAssertEqual(try install(downloaded, at: destination), destination)
        XCTAssertTrue(WhisperSupport.modelExists(in: destination))
        XCTAssertEqual(try marker(in: destination), "dst", "the complete copy is untouched")
    }

    func test_install_partialDownload_withNothingToKeep_fails_andPlacesNothing() throws {
        let downloaded = try whisperFolder("cache", files: Array(WhisperSupport.requiredFiles.dropFirst()))
        let destination = root.appendingPathComponent("dst")

        XCTAssertThrowsError(try install(downloaded, at: destination)) { error in
            XCTAssertEqual(error as? ModelInstallError, .incomplete)
        }
        XCTAssertFalse(fm.fileExists(atPath: destination.path))
    }

    func test_install_partialDownload_overAPartialDestination_fails_andLeavesItForARetry() throws {
        let downloaded = try whisperFolder("cache", files: [WhisperSupport.requiredFiles[1]])
        let destination = try whisperFolder("dst", files: [WhisperSupport.requiredFiles[0]])

        XCTAssertThrowsError(try install(downloaded, at: destination))
        XCTAssertFalse(WhisperSupport.modelExists(in: destination))
    }

    func test_install_downloadedInPlace_isCheckedToo() throws {
        let complete = try whisperFolder("complete")
        XCTAssertEqual(try install(complete, at: complete), complete)
        let partial = try whisperFolder("partial", files: [])
        XCTAssertThrowsError(try install(partial, at: partial))
    }
}
