import Foundation
import CryptoKit

/// Content hashing for imported media.
///
/// Two hashes, and the difference matters.
///
/// The **signature** is the file's size plus three 1 MB windows from the head,
/// middle and tail. It is cheap, and it is only ever a *candidate filter*: at
/// 44.1/24 a megabyte is four seconds, so two mixes of the same arrangement have
/// identical lengths and near-identical heads and tails. Treating a signature match
/// as identity is how a producer's new mix gets silently discarded as a duplicate.
///
/// The **full** hash reads every byte and is the only thing allowed to decide that
/// two files are the same file. It costs one pass over a file that has just been
/// copied anyway, and it is only paid when a signature actually collides.
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

    /// Every byte. The only hash that may be used to conclude two files are equal.
    public static func full(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: windowSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return digestString(hasher.finalize())
    }

    /// Whether two files are byte-for-byte identical.
    public static func areIdentical(_ first: URL, _ second: URL) -> Bool {
        guard let firstSize = try? fileSize(of: first),
              let secondSize = try? fileSize(of: second),
              firstSize == secondSize
        else {
            return false
        }
        guard let firstHash = try? full(ofFileAt: first),
              let secondHash = try? full(ofFileAt: second)
        else {
            return false
        }
        return firstHash == secondHash
    }

    public static func fileSize(of url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private static func digestString(_ digest: SHA256Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
