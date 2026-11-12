import Foundation

/// Snapshot of the boot volume's capacity.
struct DiskInfo {
    let total: Int64
    let available: Int64
    var used: Int64 { total - available }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    /// `volumeAvailableCapacityForImportantUsage` matches what Finder reports
    /// as free space (it counts purgeable space as available).
    static func current() -> DiskInfo {
        let values = try? URL(filePath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return DiskInfo(
            total: Int64(values?.volumeTotalCapacity ?? 0),
            available: values?.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }

    /// Space used by macOS's own volumes: the sealed system, Preboot, VM swap, Update and
    /// similar. Excludes the Data volume, which the scan measures. Read instantly, no scan.
    /// The APFS volumes macOS itself uses. Other mounts (the home-folder automount, disk images
    /// mounted inside these volumes) report misleading sizes and must not be added.
    static let macOSVolumePaths = [
        "/", "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
        "/System/Volumes/xarts", "/System/Volumes/iSCPreboot", "/System/Volumes/Hardware",
    ]

    static func macOSVolumesUsed() -> Int64 {
        macOSVolumePaths.reduce(0) { $0 + (volumeSpaceUsed($1) ?? 0) }
    }

    /// One APFS volume's own usage, as `df` reports it. (statfs reports the whole shared
    /// container for every APFS volume, so it cannot be used here.)
    static func volumeSpaceUsed(_ path: String) -> Int64? {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.volattr = attrgroup_t(0x8000_0000 | 0x0080_0000) // ATTR_VOL_INFO | ATTR_VOL_SPACEUSED
        var buffer = [UInt8](repeating: 0, count: 64)
        guard getattrlist(path, &request, &buffer, buffer.count, 0) == 0 else { return nil }
        // Layout: UInt32 length, then the 64-bit space used.
        return buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int64.self) }
    }
}
