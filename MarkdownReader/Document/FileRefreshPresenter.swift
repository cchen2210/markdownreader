@preconcurrency import AppKit
import Darwin
import Foundation

final class FileRefreshPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    private let changeHandler: @Sendable () -> Void
    private let moveHandler: @Sendable (URL) -> Void
    private let deletionHandler: @Sendable () -> Void
    private let watcherQueue = DispatchQueue(label: "MarkdownReader.FileWatcher", qos: .userInitiated)
    private let watcherQueueKey = DispatchSpecificKey<UInt8>()
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedURL: URL
    private var watcherGeneration = 0
    private var isWatching = false
    private var isRegistered = false

    var presentedItemURL: URL?

    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MarkdownReader.FilePresenter"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    init(
        url: URL,
        onChange: @escaping @Sendable () -> Void,
        onMove: @escaping @Sendable (URL) -> Void,
        onDelete: @escaping @Sendable () -> Void
    ) {
        presentedItemURL = url
        watchedURL = url.standardizedFileURL
        changeHandler = onChange
        moveHandler = onMove
        deletionHandler = onDelete
        super.init()
        watcherQueue.setSpecific(key: watcherQueueKey, value: 1)
    }

    func start() {
        guard !isRegistered else { return }
        NSFileCoordinator.addFilePresenter(self)
        isRegistered = true
        synchronouslyOnWatcherQueue {
            isWatching = true
            watcherGeneration += 1
            installWatcher(generation: watcherGeneration, retry: 0, notifyWhenReady: false)
        }
    }

    func stop() {
        guard isRegistered else { return }
        NSFileCoordinator.removeFilePresenter(self)
        isRegistered = false
        synchronouslyOnWatcherQueue {
            isWatching = false
            watcherGeneration += 1
            tearDownWatcher()
        }
    }

    deinit {
        if isRegistered {
            NSFileCoordinator.removeFilePresenter(self)
        }
        synchronouslyOnWatcherQueue {
            isWatching = false
            watcherGeneration += 1
            tearDownWatcher()
        }
    }

    func presentedItemDidChange() {
        changeHandler()
    }

    func presentedItemDidMove(to newURL: URL) {
        presentedItemURL = newURL
        watcherQueue.async { [weak self] in
            guard let self else { return }
            watchedURL = newURL.standardizedFileURL
            watcherGeneration += 1
            let generation = watcherGeneration
            tearDownWatcher()
            installWatcher(generation: generation, retry: 0, notifyWhenReady: false)
        }
        moveHandler(newURL)
        changeHandler()
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping (Error?) -> Void) {
        deletionHandler()
        completionHandler(nil)
    }

    private func installWatcher(generation: Int, retry: Int, notifyWhenReady: Bool) {
        dispatchPrecondition(condition: .onQueue(watcherQueue))
        guard isWatching, generation == watcherGeneration, watcher == nil else { return }

        let descriptor = Darwin.open(watchedURL.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            guard retry < 20 else {
                if notifyWhenReady { deletionHandler() }
                return
            }
            watcherQueue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                self?.installWatcher(
                    generation: generation,
                    retry: retry + 1,
                    notifyWhenReady: notifyWhenReady
                )
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleWatcherEvent()
        }
        source.setCancelHandler {
            Darwin.close(descriptor)
        }
        watcher = source
        source.resume()

        if notifyWhenReady {
            changeHandler()
        }
    }

    private func handleWatcherEvent() {
        dispatchPrecondition(condition: .onQueue(watcherQueue))
        guard let watcher else { return }
        let events = watcher.data
        let replacementEvents: DispatchSource.FileSystemEvent = [.delete, .rename, .revoke]

        if !events.intersection(replacementEvents).isEmpty {
            watcherGeneration += 1
            let generation = watcherGeneration
            tearDownWatcher()
            installWatcher(generation: generation, retry: 0, notifyWhenReady: true)
        } else {
            changeHandler()
        }
    }

    private func tearDownWatcher() {
        dispatchPrecondition(condition: .onQueue(watcherQueue))
        watcher?.cancel()
        watcher = nil
    }

    private func synchronouslyOnWatcherQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: watcherQueueKey) != nil {
            body()
        } else {
            watcherQueue.sync(execute: body)
        }
    }
}
