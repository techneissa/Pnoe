import Foundation

/// Turns the raw audio Ollama streams (16-bit little-endian mono PCM, 24 kHz, no header) into float samples. A network
/// chunk can end in the middle of a sample, so the decoder keeps the odd byte and joins it to the next chunk.
struct PCMSampleDecoder {
    static let sampleRate: Double = 24_000

    /// The first byte of a sample whose second byte has not arrived yet.
    private var pendingByte: UInt8?

    /// The samples completed by `bytes`, in -1...1.
    mutating func decode(_ bytes: Data) -> [Float] {
        var samples: [Float] = []
        samples.reserveCapacity((bytes.count + 1) / 2)
        var low = pendingByte
        pendingByte = nil
        for byte in bytes {
            if let first = low {
                let value = Int16(bitPattern: UInt16(first) | UInt16(byte) << 8)
                samples.append(Float(value) / 32768)
                low = nil
            } else {
                low = byte
            }
        }
        pendingByte = low
        return samples
    }

    /// True while half a sample is waiting for its second byte.
    var hasPendingByte: Bool { pendingByte != nil }

    mutating func reset() {
        pendingByte = nil
    }
}
