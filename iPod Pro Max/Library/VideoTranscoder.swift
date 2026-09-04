//
//  VideoTranscoder.swift
//  iPod Pro Max
//
//  Converts video to what click-wheel iPods play: H.264 Baseline Level 1.3, up to 320×240, ≤768 kbit/s,
//  with AAC-LC stereo audio in an MPEG-4 file. Uses AVAssetReader/Writer so the profile is under our control.
//

import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox

struct VideoInfo {
    var width: Int
    var height: Int
    var durationMs: Int
    var hasAudio: Bool
}

enum VideoTranscoder {
    static let maxWidth = 320
    static let maxHeight = 240
    static let videoBitrate = 700_000
    static let audioBitrate = 128_000
    static let maxFrameRate = 30.0

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mpg", "mpeg", "mkv", "avi", "3gp", "ts", "m2ts", "mts", "webm", "flv", "wmv", "mxf"]

    static func isVideoFile(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    static func info(for url: URL) async throws -> VideoInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let vt = try await asset.loadTracks(withMediaType: .video).first else {
            throw IPodDBError.unsupported("No video track found in \(url.lastPathComponent)")
        }
        let size = try await vt.load(.naturalSize)
        let transform = try await vt.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
        return VideoInfo(width: Int(abs(rect.width).rounded()), height: Int(abs(rect.height).rounded()),
                         durationMs: Int(CMTimeGetSeconds(duration) * 1000), hasAudio: hasAudio)
    }

    /// Produces a poster frame (JPEG data) about a second into the video.
    static func posterFrame(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 640)
        let duration = (try? await asset.load(.duration)) ?? .zero
        let t = CMTimeGetSeconds(duration) > 3 ? CMTime(seconds: 1.5, preferredTimescale: 600) : CMTime(seconds: 0, preferredTimescale: 600)
        guard let (image, _) = try? await gen.image(at: t) else { return nil }
        return ImageLoading.jpegData(from: image, maxDimension: 640)
    }

    /// Target dimensions that fit the iPod screen, even-sized, preserving aspect ratio.
    static func targetSize(width: Int, height: Int) -> (Int, Int) {
        guard width > 0, height > 0 else { return (maxWidth, maxHeight) }
        let scale = min(Double(maxWidth) / Double(width), Double(maxHeight) / Double(height), 1.0)
        var w = Int((Double(width) * scale).rounded())
        var h = Int((Double(height) * scale).rounded())
        w -= w % 2
        h -= h % 2
        return (max(w, 16), max(h, 16))
    }

    /// Returns a cached conversion when it's newer than the source, otherwise converts.
    static func cachedIPodVideo(for track: LibraryTrack, cacheDir: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dest = cacheDir.appendingPathComponent("\(track.id.uuidString).m4v")
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            let srcDate = (try? track.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let dstDate = (try? dest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if dstDate >= srcDate { return dest }
        }
        try await transcode(source: track.url, destination: dest, progress: progress)
        return dest
    }

    static func transcode(source: URL, destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let durationSeconds = max(CMTimeGetSeconds(duration), 0.001)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw IPodDBError.unsupported("No video track found in \(source.lastPathComponent)")
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let (outW, outH) = targetSize(width: Int(abs(rect.width)), height: Int(abs(rect.height)))
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Reader: decode video to BGRA at the target size; audio to PCM.
        let reader = try AVAssetReader(asset: asset)
        let videoSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                            kCVPixelBufferWidthKey as String: outW,
                                            kCVPixelBufferHeightKey as String: outH]
        let videoOut: AVAssetReaderOutput
        let composition = AVMutableVideoComposition()
        // Use a video composition so rotation metadata and scaling are applied by the reader.
        composition.renderSize = CGSize(width: outW, height: outH)
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        let scaleX = CGFloat(outW) / abs(rect.width)
        let scaleY = CGFloat(outH) / abs(rect.height)
        let scale = min(scaleX, scaleY)
        var t = transform
        // Normalize the transform so the content starts at the origin, then scale to the output.
        let origin = rect.origin
        t = t.concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
        t = t.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        layer.setTransform(t, at: .zero)
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]
        let compOut = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: videoSettings)
        compOut.videoComposition = composition
        compOut.alwaysCopiesSampleData = false
        videoOut = compOut
        guard reader.canAdd(videoOut) else { throw IPodDBError.unsupported("Can't read the video in \(source.lastPathComponent)") }
        reader.add(videoOut)

        var audioOut: AVAssetReaderTrackOutput?
        if let audioTrack {
            let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
            let out = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: pcm)
            out.alwaysCopiesSampleData = false
            if reader.canAdd(out) { reader.add(out); audioOut = out }
        }

        // Writer: H.264 Baseline (we patch the level to 1.3 afterwards) + AAC.
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = false
        let compression: [String: Any] = [
            AVVideoAverageBitRateKey: videoBitrate,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264Baseline30,
            AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCAVLC,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoMaxKeyFrameIntervalKey: 90,
            AVVideoExpectedSourceFrameRateKey: Int(min(nominalFPS > 0 ? nominalFPS : 30, maxFrameRate)),
        ]
        let videoWriterSettings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: outW, AVVideoHeightKey: outH,
                                                  AVVideoCompressionPropertiesKey: compression]
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoWriterSettings)
        videoIn.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoIn, sourcePixelBufferAttributes: videoSettings)
        guard writer.canAdd(videoIn) else { throw IPodDBError.unsupported("Can't encode video for the iPod.") }
        writer.add(videoIn)

        var audioIn: AVAssetWriterInput?
        if audioOut != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let aac: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
                                      AVEncoderBitRateKey: audioBitrate, AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aac)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) { writer.add(input); audioIn = input }
        }

        guard reader.startReading() else { throw reader.error ?? IPodDBError.unsupported("Couldn't start reading \(source.lastPathComponent)") }
        guard writer.startWriting() else { throw writer.error ?? IPodDBError.io("Couldn't start writing the converted video.") }
        writer.startSession(atSourceTime: .zero)

        let box = ProgressBox(progress: progress, duration: durationSeconds)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Self.pump(input: videoIn, queueLabel: "video") {
                    while true {
                        guard let sample = videoOut.copyNextSampleBuffer() else { return nil }
                        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                        // Drop frames above 30 fps.
                        if box.shouldDrop(pts) { continue }
                        box.report(pts)
                        return sample
                    }
                } append: { sample in
                    guard let pb = CMSampleBufferGetImageBuffer(sample) else { return true }
                    return adaptor.append(pb, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
            if let audioIn, let audioOut {
                group.addTask {
                    try await Self.pump(input: audioIn, queueLabel: "audio") {
                        audioOut.copyNextSampleBuffer()
                    } append: { sample in
                        audioIn.append(sample)
                    }
                }
            }
            try await group.waitForAll()
        }

        if reader.status == .failed { throw reader.error ?? IPodDBError.io("Reading the video failed.") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? IPodDBError.io("Writing the converted video failed.") }
        try MP4LevelPatcher.patchH264Level(in: destination, levelIDC: 13)
        progress(1)
    }

    private static func pump(input: AVAssetWriterInput, queueLabel: String,
                             next: @escaping () -> CMSampleBuffer?, append: @escaping (CMSampleBuffer) -> Bool) async throws {
        let queue = DispatchQueue(label: "ipodpromax.transcode.\(queueLabel)")
        let boxed = SendableBox(input)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) var finished = false
            boxed.value.requestMediaDataWhenReady(on: queue) {
                let input = boxed.value
                if finished { return }
                while input.isReadyForMoreMediaData {
                    if Task.isCancelled {
                        finished = true
                        input.markAsFinished()
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    guard let sample = next() else {
                        finished = true
                        input.markAsFinished()
                        cont.resume()
                        return
                    }
                    if !append(sample) {
                        finished = true
                        input.markAsFinished()
                        cont.resume(throwing: IPodDBError.io("The encoder rejected a \(queueLabel) sample."))
                        return
                    }
                }
            }
        }
    }

    private final class ProgressBox: @unchecked Sendable {
        let progress: @Sendable (Double) -> Void
        let duration: Double
        private var lastReported = -1.0
        private var lastKept = CMTime.negativeInfinity
        private let minInterval = CMTime(value: 1, timescale: 31)
        private let lock = NSLock()

        init(progress: @escaping @Sendable (Double) -> Void, duration: Double) {
            self.progress = progress
            self.duration = duration
        }

        func shouldDrop(_ pts: CMTime) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if lastKept.isValid && lastKept != .negativeInfinity, CMTimeSubtract(pts, lastKept) < minInterval { return true }
            lastKept = pts
            return false
        }

        func report(_ pts: CMTime) {
            let f = min(max(CMTimeGetSeconds(pts) / duration, 0), 1)
            lock.lock()
            let should = f - lastReported >= 0.01
            if should { lastReported = f }
            lock.unlock()
            if should { progress(f) }
        }
    }
}

final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Rewrites the H.264 level in an MP4's avcC box (and the SPS inside it) in place — the iPod checks the
/// declared level and refuses anything above 1.3, while our 320×240/700 kbit/s output is genuinely level 1.3.
enum MP4LevelPatcher {
    static func patchH264Level(in url: URL, levelIDC: UInt8) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        var patched = 0
        try walk(handle: handle, start: 0, end: Int64(size), depth: 0, levelIDC: levelIDC, patched: &patched)
        if patched == 0 { throw IPodDBError.io("Couldn't find the H.264 configuration in the converted video.") }
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    private static func walk(handle: FileHandle, start: Int64, end: Int64, depth: Int, levelIDC: UInt8, patched: inout Int) throws {
        var pos = start
        while pos + 8 <= end, depth < 12 {
            try handle.seek(toOffset: UInt64(pos))
            guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return }
            var boxSize = Int64(UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3]))
            let type = String(decoding: header[4..<8], as: UTF8.self)
            var headerLen: Int64 = 8
            if boxSize == 1, header.count >= 16 {
                var v: UInt64 = 0
                for i in 8..<16 { v = v << 8 | UInt64(header[i]) }
                boxSize = Int64(v)
                headerLen = 16
            } else if boxSize == 0 {
                boxSize = end - pos
            }
            guard boxSize >= headerLen else { return }
            let bodyStart = pos + headerLen
            let bodyEnd = min(pos + boxSize, end)
            if containers.contains(type) {
                try walk(handle: handle, start: bodyStart, end: bodyEnd, depth: depth + 1, levelIDC: levelIDC, patched: &patched)
            } else if type == "stsd" {
                try walk(handle: handle, start: bodyStart + 8, end: bodyEnd, depth: depth + 1, levelIDC: levelIDC, patched: &patched)
            } else if type == "avc1" || type == "avc3" {
                try walk(handle: handle, start: bodyStart + 78, end: bodyEnd, depth: depth + 1, levelIDC: levelIDC, patched: &patched)
            } else if type == "avcC" {
                try handle.seek(toOffset: UInt64(bodyStart))
                guard var cfg = try handle.read(upToCount: Int(bodyEnd - bodyStart)), cfg.count >= 7 else { return }
                cfg[3] = levelIDC
                let numSPS = Int(cfg[5] & 0x1F)
                var off = 6
                for _ in 0..<numSPS {
                    guard off + 2 <= cfg.count else { break }
                    let len = Int(cfg[off]) << 8 | Int(cfg[off + 1])
                    off += 2
                    if len >= 4, off + 3 < cfg.count { cfg[off + 3] = levelIDC }
                    off += len
                }
                try handle.seek(toOffset: UInt64(bodyStart))
                try handle.write(contentsOf: cfg)
                patched += 1
            }
            pos += boxSize
        }
    }
}
