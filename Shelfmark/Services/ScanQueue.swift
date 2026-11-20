import SwiftUI
import SwiftData
import UIKit

/// One captured shelf waiting for, or going through, recognition.
@MainActor
@Observable
final class ScanJob: Identifiable {
    let id = UUID()
    let shelfID: PersistentIdentifier
    let shelfLabel: String
    let mode: SaveMode
    let input: ScanInput
    let thumbnail: UIImage?
    let createdAt = Date()
    let pipeline = ScanPipeline()
    var task: Task<Void, Never>?

    init(shelf: Shelf, mode: SaveMode, input: ScanInput) {
        self.shelfID = shelf.persistentModelID
        self.shelfLabel = shelf.label
        self.mode = mode
        self.input = input
        if case .photos(let photos) = input, let first = photos.first {
            self.thumbnail = first.preparingThumbnail(of: CGSize(width: 240, height: 180)) ?? first
        } else {
            self.thumbnail = nil
        }
    }

    var isRunning: Bool { task != nil && !pipeline.stage.isFinished }
    var isWaiting: Bool { task == nil }
    var isReady: Bool { pipeline.stage == .review }
    var isFailed: Bool { if case .failed = pipeline.stage { return true }; return false }
}

/// Processes captured shelves in the background so the user can keep photographing.
/// Up to two shelves are read at once; finished shelves wait for review and saving.
@MainActor
@Observable
final class ScanQueue {
    private(set) var jobs: [ScanJob] = []
    let maxConcurrent = 2

    var readyCount: Int { jobs.filter(\.isReady).count }
    var activeCount: Int { jobs.filter { $0.isRunning || $0.isWaiting }.count }

    func enqueue(shelf: Shelf, mode: SaveMode, input: ScanInput) {
        jobs.append(ScanJob(shelf: shelf, mode: mode, input: input))
        pump()
    }

    /// Position in line for a job that hasn't started yet.
    func place(of job: ScanJob) -> Int {
        (jobs.filter(\.isWaiting).firstIndex { $0.id == job.id } ?? 0) + 1
    }

    func retry(_ job: ScanJob) {
        job.task?.cancel()
        job.task = nil
        job.pipeline.reset()
        pump()
    }

    func remove(_ job: ScanJob) {
        job.task?.cancel()
        jobs.removeAll { $0.id == job.id }
        pump()
    }

    /// Saves a finished job to its shelf and removes it from the queue.
    func save(_ job: ScanJob, context: ModelContext, router: Router) {
        guard let shelf = context.model(for: job.shelfID) as? Shelf else { return }
        if job.mode == .replace, router.highlighted?.shelf == shelf { router.highlighted = nil }
        job.pipeline.save(to: shelf, mode: job.mode, context: context)
        remove(job)
    }

    private func pump() {
        var running = jobs.filter(\.isRunning).count
        for job in jobs where job.isWaiting && running < maxConcurrent {
            running += 1
            start(job)
        }
    }

    private func start(_ job: ScanJob) {
        // Ask iOS for extra time so a scan in progress survives a brief switch to another app.
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "Shelf scan \(job.shelfLabel)") {
            token.end()
        }
        job.task = Task { [weak self] in
            await job.pipeline.run(job.input)
            token.end()
            self?.pump()
        }
    }
}

@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
