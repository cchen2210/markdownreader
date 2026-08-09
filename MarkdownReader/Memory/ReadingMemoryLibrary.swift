import Foundation

@MainActor
final class ReadingMemoryLibrary: ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var changeSequence: UInt64 = 0
    @Published private(set) var pendingNavigation: PendingMemoryNavigation?

    private(set) var repository: MemoryRepository?
    private var startupTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?

    init(repository: MemoryRepository? = nil) {
        if let repository {
            self.repository = repository
            isReady = true
            startObserving(repository)
        } else {
            startupTask = Task { [weak self] in
                let result = await Task.detached(priority: .utility) {
                    Result { try MemoryRepository.live() }
                }.value
                guard let self else { return }
                switch result {
                case let .success(repository):
                    self.repository = repository
                    self.isReady = true
                    self.errorMessage = nil
                    self.startObserving(repository)
                case let .failure(error):
                    self.isReady = false
                    self.errorMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Reading Memory is unavailable. Markdown reading is still available."
                }
            }
        }
    }

    deinit {
        startupTask?.cancel()
        observationTask?.cancel()
    }

    func requireRepository() throws -> MemoryRepository {
        guard let repository else {
            throw ReadingMemoryLibraryError.unavailable(errorMessage)
        }
        return repository
    }

    func requestNavigation(documentID: UUID, memoryID: UUID?, entersRepair: Bool = false) {
        pendingNavigation = PendingMemoryNavigation(
            token: UUID(),
            documentID: documentID,
            memoryID: memoryID,
            entersRepair: entersRepair
        )
    }

    func consumeNavigation(token: UUID) {
        guard pendingNavigation?.token == token else { return }
        pendingNavigation = nil
    }

    private func startObserving(_ repository: MemoryRepository) {
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            let stream = await repository.changes()
            for await change in stream {
                guard !Task.isCancelled else { return }
                self?.changeSequence = change.sequence
            }
        }
    }
}

struct PendingMemoryNavigation: Equatable, Sendable {
    let token: UUID
    let documentID: UUID
    let memoryID: UUID?
    let entersRepair: Bool
}

enum ReadingMemoryLibraryError: LocalizedError {
    case unavailable(String?)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message):
            message ?? "Reading Memory is still starting. Try again in a moment."
        }
    }
}
