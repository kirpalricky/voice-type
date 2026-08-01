import AVFoundation
import Foundation

/// Decodes saved audio files (AAC .m4a or legacy PCM .caf) into 16kHz mono Float32 samples,
/// the shape expected by `Transcribing.transcribe(_:)`.
enum AudioDecoder {
    static func decodeTo16kMono(fileURL: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: fileURL)

        // Target format: 16kHz mono Float32
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let processingFormat = file.processingFormat

        // Fast path: if the file is already in the target format, extract directly
        if processingFormat.sampleRate == 16000 &&
           processingFormat.channelCount == 1 &&
           processingFormat.commonFormat == .pcmFormatFloat32 {
            return try extractSamplesDirectly(file: file, format: processingFormat)
        }

        // Conversion needed: resample and/or convert channels
        return try convertAudioWithLoop(file: file, sourceFormat: processingFormat, targetFormat: targetFormat)
    }

    /// Extract samples directly from a file that's already in the target format.
    private static func extractSamplesDirectly(file: AVAudioFile, format: AVAudioFormat) throws -> [Float] {
        // Guard against corrupt files with invalid length
        guard file.length >= 0, file.length <= Int64(UInt32.max) else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        try file.read(into: buffer)

        guard let floatChannelData = buffer.floatChannelData else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(buffer.frameLength)))
        return samples
    }

    /// Convert audio using a loop to ensure the entire file is converted, not just partial content.
    /// The block-based AVAudioConverter API only guarantees full consumption across repeated invocations.
    private static func convertAudioWithLoop(file: AVAudioFile, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) throws -> [Float] {
        // Guard against corrupt files with invalid length
        guard file.length >= 0, file.length <= Int64(UInt32.max) else {
            throw AudioDecoderError.bufferAllocationFailed
        }

        let sourceFrameCount = AVAudioFrameCount(file.length)

        // Read input file into a mono buffer to handle multi-channel files
        // AVAudioFile automatically downmixes/upmixes when reading into a different channel count
        let monoReadFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceFormat.sampleRate, channels: 1, interleaved: false)!

        guard let fullInputBuffer = AVAudioPCMBuffer(pcmFormat: monoReadFormat, frameCapacity: sourceFrameCount) else {
            throw AudioDecoderError.bufferAllocationFailed
        }
        try file.read(into: fullInputBuffer)

        // Create converter from mono read format to target format
        guard let converter = AVAudioConverter(from: monoReadFormat, to: targetFormat) else {
            throw AudioDecoderError.converterUnavailable
        }

        // Calculate expected output frame count after resampling
        let ratio = targetFormat.sampleRate / monoReadFormat.sampleRate
        let expectedOutputFrames = Int(Double(sourceFrameCount) * ratio)
        let estimatedCapacity = expectedOutputFrames + 1000 // Add slack for safety

        // Accumulate output samples as we convert
        var allOutputSamples: [Float] = []
        allOutputSamples.reserveCapacity(estimatedCapacity)

        // Track position in the input buffer for the input provider
        var inputPosition: AVAudioFramePosition = 0

        // Convert in chunks using the input provider block
        while true {
            let outputCapacity: AVAudioFrameCount = 4096
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                throw AudioDecoderError.bufferAllocationFailed
            }

            var error: NSError?
            let status = converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                // Provide input from the buffer
                let remainingFrames = fullInputBuffer.frameLength - AVAudioFrameCount(inputPosition)
                if remainingFrames > 0 {
                    let framesToRead = min(AVAudioFrameCount(inNumPackets), remainingFrames)

                    // Create a view into the input buffer at the current position
                    guard let tempBuffer = AVAudioPCMBuffer(pcmFormat: monoReadFormat, frameCapacity: framesToRead) else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }

                    // Copy the requested frames
                    tempBuffer.frameLength = framesToRead
                    if let sourceData = fullInputBuffer.floatChannelData,
                       let destData = tempBuffer.floatChannelData {
                        memcpy(destData[0], sourceData[0] + Int(inputPosition), Int(framesToRead) * MemoryLayout<Float>.stride)
                    }

                    inputPosition += AVAudioFramePosition(framesToRead)
                    outStatus.pointee = .haveData
                    return tempBuffer
                } else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let error = error {
                throw error
            }

            if outputBuffer.frameLength > 0 {
                // Extract samples and accumulate
                if let floatChannelData = outputBuffer.floatChannelData {
                    let samples = Array(UnsafeBufferPointer(start: floatChannelData[0], count: Int(outputBuffer.frameLength)))
                    allOutputSamples.append(contentsOf: samples)
                }
            }

            // Stop if converter reports endOfStream or no output
            if status == .endOfStream || outputBuffer.frameLength == 0 {
                break
            }
        }

        return allOutputSamples
    }
}

enum AudioDecoderError: LocalizedError {
    case bufferAllocationFailed
    case converterUnavailable
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .bufferAllocationFailed:
            return "Failed to allocate audio buffer"
        case .converterUnavailable:
            return "Audio converter not available for the given formats"
        case .conversionFailed:
            return "Audio conversion failed"
        }
    }
}
