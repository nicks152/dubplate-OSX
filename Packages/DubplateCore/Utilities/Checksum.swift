import Foundation
import CryptoKit

/// Content hashing for imported media.
///
/// A full SHA-256 of a 45-minute 96/24 WAV is roughly a gigabyte of reading, so
/// Dubplate hashes a *signature*: the file's size plus three 1 MB windows taken from
/// the head, middle and tail. Two different bounces of the same song differ within
/// the first window in practice, and re-importing the identical file is recognised
/// without the wait. `full(of:)` is available where certainty matters.
public enum Checksum {
    public static let windowSize = 1 << 20

    public static func signature(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try fileSize(of: url)
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        let window = Int64(windowSize)
        var offsets: [Int64] = [0]
        if size > window * 2 {
            offsets.append(max(0, size / 2 - window / 2))
        }
        if size > window {
            offsets.append(max(0, size - window))
        }

        for offset in offsets {
            try handle.seek(toOffset: UInt64(offset))
            // `read(upToCount:)` is allowed to return fewer bytes than asked for,
            // and a short read part-way through a window would change the answer.
            var remaining = windowSize
            while remaining > 0 {
                guard let chunk = try handle.read(upToCount: remaining), !chunk.isEmpty else { break }
                hasher.update(data: chunk)
                remaining -= chunk.count
            }
        }
        return digestString(hasher.finalize())
    }

    public static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func digestString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
