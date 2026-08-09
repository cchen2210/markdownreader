import Darwin
import Foundation

/// Writes one already-rendered Reading Memory payload without changing its
/// bytes. The temporary file is always a sibling of the destination, so the
/// final POSIX rename is an atomic replacement on the same file system.
enum MemoryArchiveAtomicWriter {
    static func write(
        _ payload: MemoryArchivePayload,
        representation: MemoryArchiveRepresentation,
        currentStoreSequence: UInt64,
        to destinationURL: URL
    ) throws {
        try write(
            payload,
            representation: representation,
            currentStoreSequence: currentStoreSequence,
            to: destinationURL,
            coordinator: SystemMemoryArchiveFileCoordinator()
        )
    }

    static func write(
        _ payload: MemoryArchivePayload,
        representation: MemoryArchiveRepresentation,
        currentStoreSequence: UInt64,
        to destinationURL: URL,
        coordinator: any MemoryArchiveFileCoordinating
    ) throws {
        let data = try payload.data(
            for: representation,
            currentStoreSequence: currentStoreSequence
        )
        try writeExactBytes(data, to: destinationURL, coordinator: coordinator)
    }

    /// Compatibility seam for UI code that already retains the immutable
    /// preview bytes. New integrations should prefer the payload overload so a
    /// committed store mutation can invalidate the save.
    static func writeExactBytes(_ data: Data, to destinationURL: URL) throws {
        try writeExactBytes(
            data,
            to: destinationURL,
            coordinator: SystemMemoryArchiveFileCoordinator()
        )
    }

    static func writeExactBytes(
        _ data: Data,
        to destinationURL: URL,
        coordinator: any MemoryArchiveFileCoordinating
    ) throws {
        guard destinationURL.isFileURL else {
            throw MemoryArchiveWriteError.invalidDestination
        }

        try coordinator.coordinateReplacing(at: destinationURL) { coordinatedURL in
            try replaceExactBytes(data, at: coordinatedURL.standardizedFileURL)
        }
    }

    private static func replaceExactBytes(_ data: Data, at destinationURL: URL) throws {
        let fileManager = FileManager.default
        let directoryURL = destinationURL.deletingLastPathComponent()
        var directoryFlag = ObjCBool(false)
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &directoryFlag
        ), directoryFlag.boolValue else {
            throw MemoryArchiveWriteError.invalidDestination
        }

        var destinationDirectoryFlag = ObjCBool(false)
        if fileManager.fileExists(
            atPath: destinationURL.path,
            isDirectory: &destinationDirectoryFlag
        ), destinationDirectoryFlag.boolValue {
            throw MemoryArchiveWriteError.invalidDestination
        }

        let temporaryURL = try makeExclusiveTemporaryFile(
            beside: destinationURL,
            in: directoryURL
        )
        var descriptor: Int32? = temporaryURL.descriptor
        var temporaryPathExists = true

        defer {
            if let descriptor {
                _ = Darwin.close(descriptor)
            }
            if temporaryPathExists {
                temporaryURL.url.withUnsafeFileSystemRepresentation { path in
                    if let path { _ = Darwin.unlink(path) }
                }
            }
        }

        guard Darwin.fchmod(temporaryURL.descriptor, mode_t(0o600)) == 0 else {
            throw MemoryArchiveWriteError.cannotSetPrivatePermissions(errno)
        }
        try verifyPrivatePermissions(of: temporaryURL.descriptor)
        try writeAll(data, to: temporaryURL.descriptor)
        try synchronizeFile(temporaryURL.descriptor)
        descriptor = nil
        try closeFile(temporaryURL.descriptor)

        try renameReplacing(temporaryURL.url, destinationURL)
        temporaryPathExists = false
        try synchronizeDirectory(directoryURL)
    }

    private static func makeExclusiveTemporaryFile(
        beside destinationURL: URL,
        in directoryURL: URL
    ) throws -> (url: URL, descriptor: Int32) {
        let destinationName = destinationURL.lastPathComponent.isEmpty
            ? "Reading-Memory"
            : destinationURL.lastPathComponent

        for _ in 0..<8 {
            let name = ".\(destinationName).memory-export-\(UUID().uuidString.lowercased()).tmp"
            let url = directoryURL.appendingPathComponent(name, isDirectory: false)
            let descriptor = try url.withUnsafeFileSystemRepresentation { path -> Int32 in
                guard let path else {
                    throw MemoryArchiveWriteError.invalidDestination
                }
                return Darwin.open(
                    path,
                    O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
                    mode_t(0o600)
                )
            }
            if descriptor >= 0 {
                return (url, descriptor)
            }
            if errno != EEXIST {
                throw MemoryArchiveWriteError.cannotCreateTemporaryFile(errno)
            }
        }
        throw MemoryArchiveWriteError.cannotCreateTemporaryFile(EEXIST)
    }

    private static func verifyPrivatePermissions(of descriptor: Int32) throws {
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw MemoryArchiveWriteError.cannotVerifyPrivatePermissions(errno)
        }
        guard status.st_mode & mode_t(0o777) == mode_t(0o600) else {
            throw MemoryArchiveWriteError.cannotSetPrivatePermissions(EPERM)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw MemoryArchiveWriteError.cannotWriteTemporaryFile(EIO)
                }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw MemoryArchiveWriteError.cannotWriteTemporaryFile(
                        written < 0 ? errno : EIO
                    )
                }
                offset += written
            }
        }
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw MemoryArchiveWriteError.cannotSynchronizeTemporaryFile(errno)
        }
    }

    private static func closeFile(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else {
            throw MemoryArchiveWriteError.cannotCloseTemporaryFile(errno)
        }
    }

    private static func renameReplacing(_ sourceURL: URL, _ destinationURL: URL) throws {
        let result = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return Int32(-1) }
                return Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw MemoryArchiveWriteError.cannotAtomicallyReplaceDestination(errno)
        }
    }

    private static func synchronizeDirectory(_ directoryURL: URL) throws {
        let descriptor = try directoryURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else {
                throw MemoryArchiveWriteError.invalidDestination
            }
            return Darwin.open(path, O_RDONLY | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw MemoryArchiveWriteError.cannotOpenContainingDirectory(errno)
        }
        defer { _ = Darwin.close(descriptor) }

        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw MemoryArchiveWriteError.cannotSynchronizeContainingDirectory(errno)
        }
    }
}

protocol MemoryArchiveFileCoordinating {
    func coordinateReplacing(
        at destinationURL: URL,
        accessor: (URL) throws -> Void
    ) throws
}

private struct SystemMemoryArchiveFileCoordinator: MemoryArchiveFileCoordinating {
    func coordinateReplacing(
        at destinationURL: URL,
        accessor: (URL) throws -> Void
    ) throws {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var accessorError: Error?
        var didCoordinate = false

        coordinator.coordinate(
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            didCoordinate = true
            do {
                try accessor(coordinatedURL)
            } catch {
                accessorError = error
            }
        }

        if let accessorError {
            throw accessorError
        }
        if let coordinationError {
            throw MemoryArchiveWriteError.coordinationFailed(
                domain: coordinationError.domain,
                code: coordinationError.code
            )
        }
        guard didCoordinate else {
            throw MemoryArchiveWriteError.coordinationDidNotProvideDestination
        }
    }
}

enum MemoryArchiveWriteError: Error, Equatable, Sendable {
    case invalidDestination
    case coordinationFailed(domain: String, code: Int)
    case coordinationDidNotProvideDestination
    case cannotCreateTemporaryFile(Int32)
    case cannotSetPrivatePermissions(Int32)
    case cannotVerifyPrivatePermissions(Int32)
    case cannotWriteTemporaryFile(Int32)
    case cannotSynchronizeTemporaryFile(Int32)
    case cannotCloseTemporaryFile(Int32)
    case cannotAtomicallyReplaceDestination(Int32)
    case cannotOpenContainingDirectory(Int32)
    case cannotSynchronizeContainingDirectory(Int32)
}

extension MemoryArchiveWriteError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidDestination:
            return "Choose a regular file in an existing folder for the Reading Memory export."
        case .coordinationFailed, .coordinationDidNotProvideDestination:
            return "The selected location could not coordinate an atomic save. No successful save was reported."
        case .cannotCreateTemporaryFile:
            return "A private temporary export could not be created beside the selected file."
        case .cannotSetPrivatePermissions, .cannotVerifyPrivatePermissions:
            return "The export could not be restricted to your user account, so it was not saved."
        case .cannotWriteTemporaryFile, .cannotSynchronizeTemporaryFile, .cannotCloseTemporaryFile:
            return "The complete export could not be durably written, so it was not saved."
        case .cannotAtomicallyReplaceDestination:
            return "The selected location could not atomically replace the export. No successful save was reported."
        case .cannotOpenContainingDirectory:
            return "The export folder could not be opened to confirm a durable save."
        case .cannotSynchronizeContainingDirectory:
            return "The export was replaced, but macOS could not confirm the folder update was durable."
        }
    }
}
