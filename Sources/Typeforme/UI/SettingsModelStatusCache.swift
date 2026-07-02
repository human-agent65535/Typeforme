import Combine
import Foundation

struct SettingsModelFileSnapshot: Equatable {
    let path: String
    let loaded: Bool
    let exists: Bool
    let byteCount: Int64

    static func unknown(path: String) -> SettingsModelFileSnapshot {
        SettingsModelFileSnapshot(path: path, loaded: false, exists: false, byteCount: 0)
    }

    static func read(path: String, fileManager: FileManager = .default) -> SettingsModelFileSnapshot {
        guard fileManager.fileExists(atPath: path) else {
            return SettingsModelFileSnapshot(path: path, loaded: true, exists: false, byteCount: 0)
        }
        let count = (try? ModelDownloadIntegrity.byteCount(of: URL(fileURLWithPath: path))) ?? 0
        return SettingsModelFileSnapshot(path: path, loaded: true, exists: true, byteCount: count)
    }
}

struct SettingsNemotronRuntimeSnapshot: Equatable {
    let key: String
    let loaded: Bool
    let status: NvidiaNemotronASRRuntimeStatus
    let byteCountsByFileID: [String: Int64]
    let anyModelFileExists: Bool

    func byteCount(for file: NvidiaNemotronASRFileSpec) -> Int64 {
        byteCountsByFileID[file.id] ?? 0
    }
}

@MainActor
final class SettingsModelStatusCache: ObservableObject {
    @Published private var fileSnapshots: [String: SettingsModelFileSnapshot] = [:]
    @Published private var nemotronSnapshots: [String: SettingsNemotronRuntimeSnapshot] = [:]

    func fileSnapshot(path: String) -> SettingsModelFileSnapshot {
        let path = normalizedPath(path)
        return fileSnapshots[path] ?? .unknown(path: path)
    }

    func refreshFile(path: String) {
        refreshFiles(paths: [path])
    }

    func refreshFiles(paths: [String]) {
        let paths = Array(Set(paths.map(normalizedPath)))
        guard !paths.isEmpty else { return }

        var next = fileSnapshots
        for path in paths {
            next[path] = SettingsModelFileSnapshot.read(path: path)
        }
        if next != fileSnapshots {
            fileSnapshots = next
        }
    }

    func refreshLocalLlamaModel(_ spec: LocalLlamaModelSpec) {
        refreshFile(path: effectivePath(forKey: spec.pathKey, fallback: spec.defaultPath))
    }

    func localLlamaSnapshot(_ spec: LocalLlamaModelSpec) -> SettingsModelFileSnapshot {
        fileSnapshot(path: effectivePath(forKey: spec.pathKey, fallback: spec.defaultPath))
    }

    func refreshQwenASRModel(_ spec: QwenASRModelSpec) {
        refreshFiles(paths: qwenASRModelPaths(spec))
    }

    func qwenASRModelLoaded(_ spec: QwenASRModelSpec) -> Bool {
        qwenASRModelPaths(spec).allSatisfy { fileSnapshot(path: $0).loaded }
    }

    func qwenASRModelInstalled(_ spec: QwenASRModelSpec) -> Bool {
        qwenASRModelPaths(spec).allSatisfy { fileSnapshot(path: $0).exists }
    }

    func refreshNvidiaNemotronModel(_ spec: NvidiaNemotronASRModelSpec) {
        refreshNvidiaNemotronModel(spec, paths: nvidiaNemotronPaths(spec))
    }

    func refreshNvidiaNemotronModel(_ spec: NvidiaNemotronASRModelSpec, paths: [String]) {
        let paths = paths.map(normalizedPath)
        let snapshot = Self.readNvidiaNemotronSnapshot(spec: spec, paths: paths)
        if nemotronSnapshots[snapshot.key] != snapshot {
            nemotronSnapshots[snapshot.key] = snapshot
        }
    }

    func nvidiaNemotronSnapshot(_ spec: NvidiaNemotronASRModelSpec) -> SettingsNemotronRuntimeSnapshot {
        nvidiaNemotronSnapshot(spec, paths: nvidiaNemotronPaths(spec))
    }

    func nvidiaNemotronSnapshot(
        _ spec: NvidiaNemotronASRModelSpec,
        paths: [String]
    ) -> SettingsNemotronRuntimeSnapshot {
        let paths = paths.map(normalizedPath)
        let key = Self.nemotronKey(specID: spec.id, paths: paths)
        return nemotronSnapshots[key] ?? Self.unknownNvidiaNemotronSnapshot(spec: spec, paths: paths)
    }

    func effectivePath(forKey key: String, fallback: String) -> String {
        let value = UserDefaults.standard.string(forKey: key)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalizedPath(value.isEmpty ? fallback : value)
    }

    private func qwenASRModelPaths(_ spec: QwenASRModelSpec) -> [String] {
        [
            effectivePath(forKey: spec.modelPathKey, fallback: spec.defaultModelPath),
            effectivePath(forKey: spec.mmprojPathKey, fallback: spec.defaultMMProjPath),
        ]
    }

    private func nvidiaNemotronPaths(_ spec: NvidiaNemotronASRModelSpec) -> [String] {
        spec.files.map { effectivePath(forKey: $0.pathKey, fallback: $0.defaultPath) }
    }

    private func normalizedPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func readNvidiaNemotronSnapshot(
        spec: NvidiaNemotronASRModelSpec,
        paths: [String],
        fileManager: FileManager = .default
    ) -> SettingsNemotronRuntimeSnapshot {
        let runnerURL = AppPaths.bundledNvidiaNemotronRunner
        let runnerReady = runnerURL.map { fileManager.isExecutableFile(atPath: $0.path) } ?? false
        var byteCountsByFileID: [String: Int64] = [:]
        var anyModelFileExists = false
        let modelFiles = zip(spec.files, paths).map { file, path in
            let fileSnapshot = SettingsModelFileSnapshot.read(path: path, fileManager: fileManager)
            byteCountsByFileID[file.id] = fileSnapshot.byteCount
            anyModelFileExists = anyModelFileExists || fileSnapshot.exists
            let installed = file.expectedBytes > 0
                ? fileSnapshot.byteCount == file.expectedBytes
                : fileSnapshot.exists
            return NvidiaNemotronASRModelFileStatus(
                spec: file,
                url: URL(fileURLWithPath: path),
                installed: installed
            )
        }
        let status = NvidiaNemotronASRRuntimeStatus(
            runnerURL: runnerURL,
            runnerReady: runnerReady,
            modelFiles: modelFiles
        )
        let key = nemotronKey(specID: spec.id, paths: paths)
        return SettingsNemotronRuntimeSnapshot(
            key: key,
            loaded: true,
            status: status,
            byteCountsByFileID: byteCountsByFileID,
            anyModelFileExists: anyModelFileExists
        )
    }

    private static func unknownNvidiaNemotronSnapshot(
        spec: NvidiaNemotronASRModelSpec,
        paths: [String]
    ) -> SettingsNemotronRuntimeSnapshot {
        let modelFiles = zip(spec.files, paths).map { file, path in
            NvidiaNemotronASRModelFileStatus(
                spec: file,
                url: URL(fileURLWithPath: path),
                installed: false
            )
        }
        let status = NvidiaNemotronASRRuntimeStatus(
            runnerURL: AppPaths.bundledNvidiaNemotronRunner,
            runnerReady: false,
            modelFiles: modelFiles
        )
        return SettingsNemotronRuntimeSnapshot(
            key: nemotronKey(specID: spec.id, paths: paths),
            loaded: false,
            status: status,
            byteCountsByFileID: [:],
            anyModelFileExists: false
        )
    }

    private static func nemotronKey(specID: String, paths: [String]) -> String {
        ([specID] + paths).joined(separator: "||")
    }
}
