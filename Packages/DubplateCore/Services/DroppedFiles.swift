import Foundation

/// Turns what Finder handed over into a flat list of files.
///
/// A drop is very often a folder — the whole point of a bounce folder is that it is
/// a folder — so a drop handler that only understands files refuses the most
/// obvious gesture in the product. Directories are walked, packages are not
/// (a `.logicx` is a directory and is emphatically not eight tracks), and the
/// result is sorted the way Finder sorts.
public enum DroppedFiles {

    /// Bundles that are directories on disk but are one thing to a person.
    static let packageExtensions: Set<String> = [
        "logicx", "band", "ptx", "ptf", "als", "alp", "flp", "cpr", "npr",
        "reason", "rpp", "aup3", "dmg", "app", "bundle", "framework", "photoslibrary"
    ]

    /// Files worth importing, from any mixture of files and folders.
    ///
    /// - Parameter depth: how far to walk into folders. Two levels covers
    ///   `NO SIGNAL/Bounces/*.wav` without turning a dropped home folder into a
    ///   thirty-second stall.
    public static func expand(
        _ urls: [URL],
        depth: Int = 2,
        limit: Int = 500,
        fileManager: FileManager = .default
    ) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func add(_ url: URL) {
            let key = url.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(key) else { return }
            seen.insert(key)
            result.append(url)
        }

        func walk(_ url: URL, remaining: Int) {
            guard result.count < limit else { return }
            if isDirectory(url, fileManager: fileManager), !isPackage(url) {
                guard remaining > 0 else { return }
                let children = (try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )) ?? []
                for child in children.sorted(by: naturalPrecedes) {
                    walk(child, remaining: remaining - 1)
                }
            } else if isInteresting(url) {
                add(url)
            }
        }

        for url in urls {
            walk(url, remaining: depth)
        }
        return result
    }

    /// True when the drop was of folders rather than loose files, which is worth
    /// saying once in the import summary.
    public static func containsDirectory(_ urls: [URL], fileManager: FileManager = .default) -> Bool {
        urls.contains { isDirectory($0, fileManager: fileManager) && !isPackage($0) }
    }

    static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(
            atPath: url.path(percentEncoded: false),
            isDirectory: &isDirectory
        )
        return exists && isDirectory.boolValue
    }

    static func isPackage(_ url: URL) -> Bool {
        packageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isInteresting(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return FilenameParser.isAudio(name) || FilenameParser.isImage(name) || FilenameParser.isVideo(name)
    }

    static func naturalPrecedes(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.compare(
            rhs.lastPathComponent,
            options: [.numeric, .caseInsensitive, .diacriticInsensitive]
        ) == .orderedAscending
    }
}
