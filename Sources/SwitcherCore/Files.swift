public import Foundation

public enum Files {
    /// Writes through a temporary file in the same folder, so a reader never
    /// sees half a file.
    public static func writeAtomically(_ data: Data, to url: URL, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).switcher-tmp")
        try data.write(to: tmp)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let modified { attributes[.modificationDate] = modified }
        try FileManager.default.setAttributes(attributes, ofItemAtPath: tmp.path)
        guard rename(tmp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Makes `dst` a copy of `src` with its modification date. A missing
    /// `src` removes `dst`, so a snapshot restores exactly the files it had.
    public static func mirror(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            return
        }
        let data = try Data(contentsOf: src)
        try writeAtomically(data, to: dst)
        if let date = try fm.attributesOfItem(atPath: src.path)[.modificationDate] {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: dst.path)
        }
    }

    /// Keeps the newest `keep` folders of `root`, by name.
    public static func prune(_ root: URL, keep: Int) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        for name in names.dropLast(keep) {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    public static func subdirectories(of url: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}
