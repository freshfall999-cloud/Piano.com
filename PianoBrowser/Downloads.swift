import CryptoKit
import SwiftUI

/// One file being downloaded, or already saved.
final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable {
        case running, finished, cancelled
        case failed(String)
    }

    let id = UUID()
    let name: String
    @Published private(set) var received: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var speed = 0.0
    @Published private(set) var state = State.running
    @Published var connections = 1
    @Published private(set) var fileURL: URL?
    @Published private(set) var checksum = ""
    var cancelAction: (() -> Void)?
    var onChange: (() -> Void)?

    private var lastPublish = ProcessInfo.processInfo.systemUptime
    private var lastReceived: Int64 = 0

    init(name: String, total: Int64) {
        self.name = name
        self.total = max(total, 0)
    }

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }

    /// Called often; publishes a few times a second so lists don't redraw for every chunk.
    func progress(received newValue: Int64, total newTotal: Int64) {
        guard state == .running else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastPublish >= 0.3 || newValue == newTotal else { return }
        let current = Double(newValue - lastReceived) / max(now - lastPublish, 0.05)
        speed = speed == 0 ? current : speed * 0.6 + current * 0.4
        lastPublish = now
        lastReceived = newValue
        received = newValue
        if newTotal > 0 { total = newTotal }
    }

    func finish(file: URL) {
        guard state == .running else { return }
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? received
        received = size
        total = size
        fileURL = file
        state = .finished
        cancelAction = nil
        #if DEBUG
        if size < 64 << 20, let data = try? Data(contentsOf: file) {
            checksum = SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
        }
        #endif
        onChange?()
    }

    func fail(_ message: String) {
        guard state == .running else { return }
        state = .failed(message)
        cancelAction = nil
        onChange?()
    }

    func cancel() {
        guard state == .running else { return }
        state = .cancelled
        cancelAction?()
        cancelAction = nil
        onChange?()
    }

    static func uniqueDestination(for suggested: String) -> URL {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let cleaned = suggested.replacingOccurrences(of: "/", with: "-")
        let name = cleaned.isEmpty ? "Download" : cleaned
        var destination = folder.appendingPathComponent(name)
        var copy = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(copy)" : "\(base) \(copy).\(ext)")
            copy += 1
        }
        return destination
    }
}

/// Downloads a large file as four pieces at once and joins them, which is faster on
/// servers that limit the speed of each connection. Falls back to one ordinary
/// download if the server won't serve pieces.
final class FastDownloader: NSObject, URLSessionDownloadDelegate {
    static let minimumSize: Int64 = 8 << 20
    private static let segmentCount = 4

    private struct Segment {
        let lower: Int64
        let upper: Int64
        var written: Int64 = 0
        var attempts = 0
        var file: URL?
        var task: URLSessionDownloadTask?
        var rangeIgnored = false
    }

    private let request: URLRequest
    private let total: Int64
    private let validator: String?
    private let destination: URL
    private let item: DownloadItem
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var session: URLSession?
    private var segments: [Segment] = []
    private var single = false
    private var done = false

    init(request: URLRequest, total: Int64, validator: String?, destination: URL, item: DownloadItem) {
        self.request = request
        self.total = total
        self.validator = validator
        self.destination = destination
        self.item = item
    }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)

        let count = Int64(FastDownloader.segmentCount)
        let size = total / count
        segments = (0..<count).map { index in
            Segment(lower: index * size, upper: index == count - 1 ? total - 1 : (index + 1) * size - 1)
        }
        item.connections = segments.count
        segments.indices.forEach(startSegment)
    }

    func cancel() {
        done = true
        session?.invalidateAndCancel()
        try? FileManager.default.removeItem(at: folder)
    }

    private func startSegment(_ index: Int) {
        guard let session else { return }
        var request = self.request
        if !single {
            request.setValue("bytes=\(segments[index].lower)-\(segments[index].upper)", forHTTPHeaderField: "Range")
            if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.downloadTask(with: request)
        task.taskDescription = String(index)
        segments[index].task = task
        segments[index].written = 0
        segments[index].file = nil
        segments[index].attempts += 1
        task.resume()
    }

    /// The server ignored the piece request, so fetch the file the ordinary way.
    private func startSingle() {
        let old = segments
        single = true
        segments = [Segment(lower: 0, upper: total - 1)]
        old.forEach { $0.task?.cancel() }
        item.connections = 1
        startSegment(0)
    }

    private func index(of task: URLSessionTask) -> Int? {
        guard !done, let index = Int(task.taskDescription ?? ""), segments.indices.contains(index),
              segments[index].task === task else { return nil }
        return index
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let index = index(of: downloadTask) else { return }
        segments[index].written = totalBytesWritten
        item.progress(received: segments.reduce(0) { $0 + $1.written }, total: total)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let index = index(of: downloadTask) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? -1
        let expected = segments[index].upper - segments[index].lower + 1
        if !single && status == 200 {
            segments[index].rangeIgnored = true
        } else if size == expected && (single ? (200..<300).contains(status) : status == 206) {
            let part = folder.appendingPathComponent("part\(index)-\(segments[index].attempts)")
            if (try? FileManager.default.moveItem(at: location, to: part)) != nil { segments[index].file = part }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let index = index(of: task) else { return }
        if segments[index].rangeIgnored {
            startSingle()
        } else if segments[index].file != nil {
            if segments.allSatisfy({ $0.file != nil }) { assemble() }
        } else if segments[index].attempts < 3 {
            startSegment(index)
        } else {
            fail(error?.localizedDescription ?? "The server sent an incomplete file.")
        }
    }

    private func fail(_ message: String) {
        cancel()
        item.fail(message)
    }

    private func assemble() {
        done = true
        session?.finishTasksAndInvalidate()
        let parts = segments.compactMap(\.file)
        let (folder, destination, total, item) = (self.folder, self.destination, self.total, self.item)
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: String?
            do {
                if parts.count == 1 {
                    try FileManager.default.moveItem(at: parts[0], to: destination)
                } else {
                    let joined = folder.appendingPathComponent("joined")
                    FileManager.default.createFile(atPath: joined.path, contents: nil)
                    let output = try FileHandle(forWritingTo: joined)
                    for part in parts {
                        let input = try FileHandle(forReadingFrom: part)
                        while true {
                            let more: Bool = try autoreleasepool {
                                guard let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty else { return false }
                                try output.write(contentsOf: chunk)
                                return true
                            }
                            if !more { break }
                        }
                        try input.close()
                    }
                    try output.close()
                    let size = ((try FileManager.default.attributesOfItem(atPath: joined.path))[.size] as? NSNumber)?.int64Value
                    guard size == total else { throw CocoaError(.fileReadCorruptFile) }
                    try FileManager.default.moveItem(at: joined, to: destination)
                }
            } catch {
                failure = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: folder)
            DispatchQueue.main.async {
                if let failure { item.fail(failure) } else { item.finish(file: destination) }
            }
        }
    }
}

/// A download's name, progress, speed and actions; used in the banner and the downloads list.
struct DownloadRow: View {
    @ObservedObject var item: DownloadItem

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var detail: String {
        switch item.state {
        case .running:
            var text = item.total > 0 ? "\(size(item.received)) of \(size(item.total))" : size(item.received)
            if item.speed > 0 { text += " · \(size(Int64(item.speed)))/s" }
            if item.connections > 1 { text += " · \(item.connections) connections" }
            return text
        case .finished:
            return "\(size(item.total)) · Saved to Files › Piano Browser" + (item.checksum.isEmpty ? "" : " · \(item.checksum)")
        case .cancelled:
            return "Cancelled"
        case .failed(let message):
            return "Failed: \(message)"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                switch item.state {
                case .running:
                    Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 3)
                    Circle().trim(from: 0, to: max(0.03, item.fraction))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down").font(.system(size: 11, weight: .bold)).foregroundStyle(.tint)
                case .finished:
                    Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
                default:
                    Image(systemName: "exclamationmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).lineLimit(1)
                Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            if item.state == .running {
                Button { item.cancel() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel download")
            } else if let file = item.fileURL {
                ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Share or open")
            }
        }
    }
}
