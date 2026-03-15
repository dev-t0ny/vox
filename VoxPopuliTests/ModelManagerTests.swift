import XCTest
@testable import VoxPopuli

final class ModelManagerTests: XCTestCase {

    private var tempDirectory: URL!
    private var manager: ModelManager!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoxPopuliTests-\(UUID().uuidString)")
        manager = ModelManager(modelsDirectory: tempDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        manager = nil
        tempDirectory = nil
        super.tearDown()
    }

    func testModelsDirectoryCreated() {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: tempDirectory.path,
            isDirectory: &isDirectory
        )
        XCTAssertTrue(exists, "Models directory should be created on init")
        XCTAssertTrue(isDirectory.boolValue, "Models path should be a directory")
    }

    func testAvailableModels() {
        let names = ModelManager.whisperModels.map { $0.name }
        XCTAssertTrue(names.contains("tiny"), "Should contain tiny model")
        XCTAssertTrue(names.contains("base"), "Should contain base model")
        XCTAssertTrue(names.contains("large-v3"), "Should contain large-v3 model")
    }

    func testModelPathForName() {
        let path = manager.modelPath(for: "base")
        XCTAssertTrue(
            path.lastPathComponent.contains("ggml-base.bin"),
            "Model path should contain ggml-base.bin, got: \(path.lastPathComponent)"
        )
    }

    func testIsModelDownloadedReturnsFalseWhenMissing() {
        XCTAssertFalse(
            manager.isModelDownloaded("base"),
            "Should return false when model file does not exist"
        )
    }

    func testIsModelDownloadedReturnsTrueWhenPresent() {
        let path = manager.modelPath(for: "base")
        FileManager.default.createFile(atPath: path.path, contents: Data("fake".utf8))

        XCTAssertTrue(
            manager.isModelDownloaded("base"),
            "Should return true when model file exists"
        )
    }

    func testMemoryCheckForSmallModel() {
        let result = manager.checkMemoryForModel("base")
        switch result {
        case .canLoad:
            // Expected on modern Macs with sufficient memory
            break
        case .lowMemory:
            // Acceptable — still means the system recognizes the model
            break
        case .insufficientMemory:
            XCTFail("Base model should be loadable on modern Mac hardware")
        }
    }
}
