import Foundation
import SwiftDate
import UIKit

final class SimpleLogReporter: IssueReporter {
    private let fileManager = FileManager.default

    /// Guards `buffer`, `bufferCreatedAt` and `logFileCreationDay`; `log` can
    /// be called from any thread.
    private let bufferLock = NSRecursiveLock(label: "SimpleLogReporter.bufferLock")

    /// Pending log lines not yet written to disk. Every small append dirties
    /// a full filesystem page, so writing per-line adds up to >1 GB/day of
    /// disk writes at Trio's log volume — enough to trip iOS's disk-write
    /// resource limit. Lines are buffered and flushed in batches instead.
    private var buffer = Data()
    private var bufferCreatedAt: Date?

    /// Cached start-of-day of the current log file's creation date, so
    /// rotation doesn't require file-metadata reads on every log call.
    private var logFileCreationDay: Date?

    private var lifecycleObservers: [NSObjectProtocol] = []

    private enum Config {
        static let maxBufferBytes = 16 * 1024
        static let maxBufferAge: TimeInterval = 30
    }

    /// Last-created instance, so call sites that read the log files off disk
    /// (e.g. Settings "Share Logs") can flush pending lines first.
    private(set) static weak var shared: SimpleLogReporter?

    init() {
        // Flush pending lines whenever the app is about to lose execution
        // time, so suspension or termination doesn't drop them.
        let center = NotificationCenter.default
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.flush()
            })
        }
        SimpleLogReporter.shared = self
    }

    deinit {
        lifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private var dateFormatter: DateFormatter {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return dateFormatter
    }

    func setup() {}

    func setUserIdentifier(_: String?) {}

    func reportNonFatalIssue(withName _: String, attributes _: [String: String]) {}

    func reportNonFatalIssue(withError _: NSError) {}

    func log(_ category: String, _ message: String, file: String, function: String, line: UInt) {
        let now = Date()
        let logEntry = "\(dateFormatter.string(from: now)) [\(category)] \(file.file) - \(function) - \(line) - \(message)\n"
        // Warnings and errors are flushed immediately: they are exactly the
        // lines that must survive if the process dies shortly after.
        let isUrgent = message.hasPrefix("WARN:") || message.hasPrefix("ERR:")

        bufferLock.perform {
            rotateIfNeeded(now: now)

            if buffer.isEmpty {
                bufferCreatedAt = now
            }
            buffer.append(logEntry.data(using: .utf8)!)

            let bufferAge = now.timeIntervalSince(bufferCreatedAt ?? now)
            if isUrgent || buffer.count >= Config.maxBufferBytes || bufferAge >= Config.maxBufferAge {
                flushLocked()
            }
        }
    }

    /// Writes any pending buffered lines to disk. Safe to call from any thread.
    func flush() {
        bufferLock.perform { flushLocked() }
    }

    /// Must be called while holding `bufferLock`.
    private func flushLocked() {
        guard !buffer.isEmpty else { return }
        try? buffer.append(fileURL: URL(fileURLWithPath: SimpleLogReporter.logFile))
        buffer.removeAll(keepingCapacity: true)
        bufferCreatedAt = nil
    }

    /// Rotates the daily log file. File-existence and creation-date checks
    /// only hit the filesystem once per process launch (and once per day
    /// rollover); afterwards the cached `logFileCreationDay` decides.
    /// Must be called while holding `bufferLock`.
    private func rotateIfNeeded(now: Date) {
        let startOfDay = Calendar.current.startOfDay(for: now)

        if logFileCreationDay == nil {
            if !fileManager.fileExists(atPath: SimpleLogReporter.logDir) {
                try? fileManager.createDirectory(
                    atPath: SimpleLogReporter.logDir,
                    withIntermediateDirectories: false,
                    attributes: nil
                )
            }

            if !fileManager.fileExists(atPath: SimpleLogReporter.logFile) {
                createFile(at: startOfDay)
                logFileCreationDay = startOfDay
            } else if let attributes = try? fileManager.attributesOfItem(atPath: SimpleLogReporter.logFile),
                      let creationDate = attributes[.creationDate] as? Date
            {
                logFileCreationDay = Calendar.current.startOfDay(for: creationDate)
            } else {
                logFileCreationDay = startOfDay
            }
        }

        guard let creationDay = logFileCreationDay, creationDay < startOfDay else { return }

        // Write pending lines to the old day's file before rotating it away.
        flushLocked()
        try? fileManager.removeItem(atPath: SimpleLogReporter.logFilePrev)
        try? fileManager.moveItem(atPath: SimpleLogReporter.logFile, toPath: SimpleLogReporter.logFilePrev)
        createFile(at: startOfDay)
        logFileCreationDay = startOfDay
    }

    private func createFile(at date: Date) {
        fileManager.createFile(atPath: SimpleLogReporter.logFile, contents: nil, attributes: [.creationDate: date])
    }

    static var logFile: String {
        getDocumentsDirectory().appendingPathComponent("logs/log.txt").path
    }

    static var logDir: String {
        getDocumentsDirectory().appendingPathComponent("logs").path
    }

    static var logFilePrev: String {
        getDocumentsDirectory().appendingPathComponent("logs/log_prev.txt").path
    }

    static func getDocumentsDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        return documentsDirectory
    }
}

extension SimpleLogReporter {
    static var watchLogFile: String {
        getDocumentsDirectory().appendingPathComponent("logs/watch_log.txt").path
    }

    static var watchLogFilePrev: String {
        getDocumentsDirectory().appendingPathComponent("logs/watch_log_prev.txt").path
    }

    static func appendToWatchLog(_ logContent: String) {
        let fileManager = FileManager.default
        let logDir = getDocumentsDirectory().appendingPathComponent("logs")
        let logFile = URL(fileURLWithPath: watchLogFile)
        let prevLogFile = URL(fileURLWithPath: watchLogFilePrev)

        let now = Date()
        let startOfDay = Calendar.current.startOfDay(for: now)

        // Create logs directory if needed
        if !fileManager.fileExists(atPath: logDir.path) {
            try? fileManager.createDirectory(at: logDir, withIntermediateDirectories: true)
        }

        // Rotate if needed
        if fileManager.fileExists(atPath: logFile.path),
           let attributes = try? fileManager.attributesOfItem(atPath: logFile.path),
           let creationDate = attributes[.creationDate] as? Date,
           creationDate < startOfDay
        {
            try? fileManager.removeItem(at: prevLogFile)
            try? fileManager.moveItem(at: logFile, to: prevLogFile)
            fileManager.createFile(atPath: logFile.path, contents: nil, attributes: [.creationDate: startOfDay])
        }

        if let data = (logContent + "\n").data(using: .utf8) {
            try? data.append(fileURL: logFile)
        }
    }
}

private extension Data {
    func append(fileURL: URL) throws {
        if let fileHandle = FileHandle(forWritingAtPath: fileURL.path) {
            defer {
                fileHandle.closeFile()
            }
            fileHandle.seekToEndOfFile()
            fileHandle.write(self)
        } else {
            try write(to: fileURL, options: .atomic)
        }
    }
}

private extension String {
    var file: String { components(separatedBy: "/").last ?? "" }
}
