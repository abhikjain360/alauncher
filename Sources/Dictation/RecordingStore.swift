import AVFoundation
import Core
import Foundation

final class RecordingStore: @unchecked Sendable {
    private let directory: URL
    private var limit: Int
    private let lock = NSLock()

    init(directory: URL = Paths.supportDirectory.appendingPathComponent("recordings", isDirectory: true), limit: Int) {
        self.directory = directory
        self.limit = max(0, limit)
        Paths.ensure(directory)
    }

    func update(limit: Int) {
        lock.lock()
        self.limit = max(0, limit)
        lock.unlock()
    }

    @discardableResult
    func save(_ samples: [Float], name: String) -> Task<Void, Never> {
        let directory = self.directory
        lock.lock()
        let limit = self.limit
        lock.unlock()
        let lock = self.lock
        return Task.detached(priority: .utility) {
            Self.write(samples, name: name, directory: directory, limit: limit, lock: lock)
        }
    }

    private static func write(_ samples: [Float], name: String, directory: URL, limit: Int, lock: NSLock) {
        lock.lock()
        defer { lock.unlock() }
        do {
            Paths.ensure(directory)
            let url = directory.appendingPathComponent(name)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            let capacity = AVAudioFrameCount(max(1, samples.count))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
                  let data = buffer.floatChannelData?[0] else {
                throw RecordingError.couldNotCreateBuffer
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                data[index] = max(-1, min(1, sample))
            }
            try file.write(from: buffer)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "wav" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if files.count > limit {
                for file in files.prefix(files.count - limit) {
                    try FileManager.default.removeItem(at: file)
                }
            }
        } catch {
            Log.main("recordings: could not save \(name)")
        }
    }

    static func fileName(date: Date = Date(), generation: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: date))-\(generation).wav"
    }
}

private enum RecordingError: Error {
    case couldNotCreateBuffer
}
