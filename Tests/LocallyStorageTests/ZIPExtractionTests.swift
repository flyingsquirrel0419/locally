import XCTest
@testable import LocallyStorage
import LocallyCore

/// ZIP extraction safety: fixtures were generated with python3's zipfile
/// (see Tests/Fixtures/Archives) including hostile variants.
final class ZIPExtractionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // LocallyStorageTests
            .deletingLastPathComponent()  // Tests
            .appendingPathComponent("Fixtures/Archives/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "missing fixture \(name)")
        return url
    }

    // MARK: - Happy path

    func testGoodArchiveExtractsStoredAndDeflatedEntries() throws {
        let archive = try fixture("good.zip")
        let plan = try ZIPExtractionPlan(archiveAt: archive)
        XCTAssertEqual(plan.entries.count, 4)
        try ZIPExtractor().extract(archiveAt: archive, plan: plan, to: tempDir)

        let meta = try Data(contentsOf: tempDir.appendingPathComponent(
            "TextEncoder.mlmodelc/metadata.json"))
        XCTAssertEqual(String(data: meta, encoding: .utf8), #"{"name":"text-encoder"}"#)

        let merges = try String(contentsOf: tempDir.appendingPathComponent("merges.txt"),
                                encoding: .utf8)
        XCTAssertTrue(merges.contains("#version: 0.2"))

        let weights = try Data(contentsOf: tempDir.appendingPathComponent(
            "Unet.mlmodelc/weights/weight.bin"))
        XCTAssertEqual(weights.count, 256 * 40)
        XCTAssertEqual(Array(weights.prefix(4)), [0, 1, 2, 3])
    }

    func testZip64ArchiveParsesAndExtracts() throws {
        let archive = try fixture("zip64.zip")
        let plan = try ZIPExtractionPlan(archiveAt: archive)
        XCTAssertEqual(plan.entries.count, 1)
        XCTAssertEqual(plan.entries[0].path, "model/config.json")
        XCTAssertEqual(plan.entries[0].uncompressedSize, 280)
        try ZIPExtractor().extract(archiveAt: archive, plan: plan, to: tempDir)
        let data = try Data(contentsOf: tempDir.appendingPathComponent("model/config.json"))
        XCTAssertEqual(data.count, 280)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.hasPrefix(#"{"zip64":true}"#))
    }

    func testStreamingExtractorHandlesChunkBoundaries() throws {
        // big.zip holds ~3 MB of deflatable content, crossing the 512 KB
        // chunk boundaries in both the compressed and output streams.
        let archive = try fixture("big.zip")
        let plan = try ZIPExtractionPlan(archiveAt: archive)
        try ZIPExtractor().extract(archiveAt: archive, plan: plan, to: tempDir)
        let data = try Data(contentsOf: tempDir.appendingPathComponent("weights/blob.bin"))
        XCTAssertEqual(UInt64(data.count), plan.entries[0].uncompressedSize)
    }

    // MARK: - Hostile archives

    func testPathTraversalEntryRejected() throws {
        let archive = try fixture("traversal.zip")
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: archive)) { error in
            guard case ZIPExtractionPlan.PlanError.unsafeEntry(let detail) = error else {
                return XCTFail("expected unsafeEntry, got \(error)")
            }
            XCTAssertTrue(detail.contains("evil"))
        }
    }

    func testSymlinkEntryRejected() throws {
        let archive = try fixture("symlink.zip")
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: archive)) { error in
            guard case ZIPExtractionPlan.PlanError.unsafeEntry = error else {
                return XCTFail("expected unsafeEntry, got \(error)")
            }
        }
    }

    func testCompressionBombRejected() throws {
        let archive = try fixture("bomb.zip")
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: archive)) { error in
            guard case ZIPExtractionPlan.PlanError.limitExceeded(let detail) = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
            XCTAssertTrue(detail.contains("ratio"))
        }
    }

    func testCorruptedCRCFailsExtraction() throws {
        let archive = try fixture("badcrc.zip")
        // The plan doesn't know the CRC is wrong (it trusts the central
        // directory); the extractor verifies the inflated bytes.
        let plan = try ZIPExtractionPlan(archiveAt: archive)
        XCTAssertThrowsError(try ZIPExtractor().extract(archiveAt: archive,
                                                        plan: plan, to: tempDir)) { error in
            guard case ZIPExtractor.ExtractError.crcMismatch = error else {
                return XCTFail("expected crcMismatch, got \(error)")
            }
        }
        // The failed entry must not be left behind.
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("data.txt").path))
    }

    func testNotAZipRejected() throws {
        let bogus = tempDir.appendingPathComponent("bogus.zip")
        try Data(repeating: 0xAB, count: 512).write(to: bogus)
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: bogus)) { error in
            guard case ZIPExtractionPlan.PlanError.notAZip = error else {
                return XCTFail("expected notAZip, got \(error)")
            }
        }
    }

    // MARK: - Limits

    func testEntryCountLimitEnforced() throws {
        let archive = try fixture("good.zip")
        let limits = ZIPExtractionPlan.Limits(maxEntries: 2,
                                              maxTotalUncompressedBytes: .max,
                                              maxEntryUncompressedBytes: .max,
                                              maxCompressionRatio: .infinity)
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: archive, limits: limits)) { error in
            guard case ZIPExtractionPlan.PlanError.limitExceeded = error else {
                return XCTFail("expected limitExceeded, got \(error)")
            }
        }
    }

    func testTotalSizeLimitEnforced() throws {
        let archive = try fixture("good.zip")
        let limits = ZIPExtractionPlan.Limits(maxEntries: 100,
                                              maxTotalUncompressedBytes: 100,
                                              maxEntryUncompressedBytes: .max,
                                              maxCompressionRatio: .infinity)
        XCTAssertThrowsError(try ZIPExtractionPlan(archiveAt: archive, limits: limits))
    }

    // MARK: - ArchiveInstaller

    func testArchiveInstallerExtractsAndDeletesZip() throws {
        let archive = try fixture("good.zip")
        let destZip = tempDir.appendingPathComponent("model.zip")
        try FileManager.default.copyItem(at: archive, to: destZip)
        let extracted = try ArchiveInstaller().extractArchives(in: tempDir)
        XCTAssertEqual(extracted, ["model.zip"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: destZip.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent("vocab.json").path))
    }

    func testArchiveInstallerLeavesNonArchivesAlone() throws {
        let plain = tempDir.appendingPathComponent("weights.bin")
        try Data([1, 2, 3]).write(to: plain)
        let extracted = try ArchiveInstaller().extractArchives(in: tempDir)
        XCTAssertTrue(extracted.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plain.path))
    }
}
