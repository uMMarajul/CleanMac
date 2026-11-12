import Foundation
import SwiftData

enum SafetyClassification: String, Codable {
    case safe
    case reviewRequired
    case protected
}

@Model
final class ScannedFile {
    var filePath: String
    var fileName: String
    var fileSize: Int64
    var allocatedSize: Int64
    var fileType: String
    var category: String
    var modifiedDate: Date?
    var lastAccessedDate: Date?
    var safetyClassification: SafetyClassification
    var scanDate: Date

    init(
        filePath: String,
        fileName: String,
        fileSize: Int64,
        allocatedSize: Int64,
        fileType: String,
        category: String,
        modifiedDate: Date? = nil,
        lastAccessedDate: Date? = nil,
        safetyClassification: SafetyClassification,
        scanDate: Date = .now
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.allocatedSize = allocatedSize
        self.fileType = fileType
        self.category = category
        self.modifiedDate = modifiedDate
        self.lastAccessedDate = lastAccessedDate
        self.safetyClassification = safetyClassification
        self.scanDate = scanDate
    }
}

@Model
final class InstalledApp {
    var name: String
    var bundleIdentifier: String
    var version: String
    var installationPath: String
    var bundleSize: Int64
    var associatedDataSize: Int64
    var lastOpenedDate: Date?
    var usageClassification: String
    /// Locked by System Integrity Protection; cannot be uninstalled.
    var isProtected: Bool = false
    /// App group identifiers from the code signature, to detect shared Group Containers.
    var appGroups: [String] = []

    init(
        name: String,
        bundleIdentifier: String,
        version: String,
        installationPath: String,
        bundleSize: Int64,
        associatedDataSize: Int64 = 0,
        lastOpenedDate: Date? = nil,
        usageClassification: String = "Unknown",
        isProtected: Bool = false,
        appGroups: [String] = []
    ) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.version = version
        self.installationPath = installationPath
        self.bundleSize = bundleSize
        self.associatedDataSize = associatedDataSize
        self.lastOpenedDate = lastOpenedDate
        self.usageClassification = usageClassification
        self.isProtected = isProtected
        self.appGroups = appGroups
    }

    var totalSize: Int64 { bundleSize + associatedDataSize }
    var lastOpenedSort: Date { lastOpenedDate ?? .distantPast }
    var url: URL { URL(filePath: installationPath) }
}

@Model
final class CleanupRecord {
    var filePath: String
    var originalLocation: String
    var deletedSize: Int64
    var cleanupDate: Date
    var operationType: String
    /// "inTrash", "restored" or "permanent". Whether an "inTrash" item is still there is checked live.
    var recoveryStatus: String
    /// StorageCategory raw value, so Put Back can return the item to its list.
    var category: String?

    init(
        filePath: String,
        originalLocation: String,
        deletedSize: Int64,
        cleanupDate: Date = .now,
        operationType: String,
        recoveryStatus: String = "inTrash",
        category: String? = nil
    ) {
        self.filePath = filePath
        self.originalLocation = originalLocation
        self.deletedSize = deletedSize
        self.cleanupDate = cleanupDate
        self.operationType = operationType
        self.recoveryStatus = recoveryStatus
        self.category = category
    }
}

@Model
final class ScanSession {
    var scanType: String
    var startTime: Date
    var endTime: Date?
    var totalScannedSize: Int64
    var categorizedSize: Int64
    var estimatedRecoverableSize: Int64

    init(
        scanType: String,
        startTime: Date = .now,
        endTime: Date? = nil,
        totalScannedSize: Int64 = 0,
        categorizedSize: Int64 = 0,
        estimatedRecoverableSize: Int64 = 0
    ) {
        self.scanType = scanType
        self.startTime = startTime
        self.endTime = endTime
        self.totalScannedSize = totalScannedSize
        self.categorizedSize = categorizedSize
        self.estimatedRecoverableSize = estimatedRecoverableSize
    }
}
