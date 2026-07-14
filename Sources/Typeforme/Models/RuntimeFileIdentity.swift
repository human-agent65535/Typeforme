import Foundation

/// A cache key component for a runtime file at one point in time. Path alone
/// is insufficient because model installers atomically replace files in place.
enum RuntimeFileIdentity {
    static func capture(_ url: URL, fileManager: FileManager = .default) -> String {
        let resolvedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return "\(resolvedPath):missing"
        }
        let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(resolvedPath):device=\(device):inode=\(inode):size=\(size):mtime=\(modified)"
    }
}
