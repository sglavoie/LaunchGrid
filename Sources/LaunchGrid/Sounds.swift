import AVFoundation
import AppKit

/// Soft sounds for the grid's moments, off unless chosen in Settings › Appearance: a breath of air
/// as it shows, a tick as a page turns, a muted knock as a folder forms and a tap as a dropped
/// icon lands. Made here from a few lines of arithmetic rather than shipped as files, quiet,
/// and silent when "Play user interface sound effects" is off in System Settings › Sound.
@MainActor
enum Sounds {
    enum Effect: CaseIterable {
        case show, page, folder, drop
    }

    /// Mirrors `Preferences.playSounds`.
    static var enabled = false
    /// Effects asked for so far, played or not, for the debug scripts.
    static var requested: [Effect] = []

    private static let engine = AVAudioEngine()
    /// Whether the engine is running now, for the debug scripts.
    static var engineRunning: Bool { engine.isRunning }
    private static var players: [Effect: AVAudioPlayerNode] = [:]
    private static var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private static var lastPlayed: [Effect: CFTimeInterval] = [:]
    private static var idleStop: Task<Void, Never>?
    private static let rate: Double = 44_100

    static func play(_ effect: Effect) {
        requested.append(effect)
        if requested.count > 100 { requested.removeFirst(50) }
        guard enabled, systemAllows else { return }
        // A page flipped through quickly ticks once per page, not a buzz.
        let now = CACurrentMediaTime()
        if let last = lastPlayed[effect], now - last < 0.05 { return }
        lastPlayed[effect] = now
        guard prepare(), let player = players[effect], let buffer = buffers[effect] else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        player.play()
        // The engine only runs while sounds are playing: stopped after a few quiet seconds.
        idleStop?.cancel()
        idleStop = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            engine.stop()
        }
    }

    /// The user's own choice in System Settings › Sound.
    private static var systemAllows: Bool {
        UserDefaults(suiteName: "com.apple.systemsound")?.object(forKey: "com.apple.sound.uiaudio.enabled") as? Bool ?? true
    }

    private static func prepare() -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return false }
        if players.isEmpty {
            for effect in Effect.allCases {
                let player = AVAudioPlayerNode()
                engine.attach(player)
                engine.connect(player, to: engine.mainMixerNode, format: format)
                players[effect] = player
                buffers[effect] = buffer(samples(effect), format: format)
            }
        }
        if !engine.isRunning {
            do { try engine.start() } catch { return false }
        }
        return true
    }

    private static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = b.floatChannelData?[0] else { return nil }
        b.frameLength = AVAudioFrameCount(samples.count)
        for (i, s) in samples.enumerated() { channel[i] = s }
        return b
    }

    /// Each effect's waveform, from -1 to 1 scaled to its loudness.
    static func samples(_ effect: Effect) -> [Float] {
        var noise = SystemRandomNumberGenerator()
        func white() -> Double { Double.random(in: -1...1, using: &noise) }
        switch effect {
        case .show:
            // Air: noise through a low-pass whose cutoff rises and falls, swelling in and out.
            let n = Int(rate * 0.32)
            var low = 0.0, out: [Float] = []
            out.reserveCapacity(n)
            for i in 0..<n {
                let t = Double(i) / Double(n)
                let cutoff = 400 + 2600 * sin(.pi * t)
                let a = 1 - exp(-2 * .pi * cutoff / rate)
                low += a * (white() - low)
                let envelope = pow(sin(.pi * t), 1.6)
                out.append(Float(low * envelope * 0.16))
            }
            return out
        case .page:
            // A short, bright tick.
            let n = Int(rate * 0.03)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let tone = sin(2 * .pi * 2300 * t) * 0.7 + white() * 0.3
                return Float(tone * exp(-t * 180) * 0.07)
            }
        case .folder:
            // A muted knock: a low tone falling in pitch, with a soft click on top.
            let n = Int(rate * 0.16)
            var phase = 0.0
            return (0..<n).map { i in
                let t = Double(i) / rate
                phase += 2 * .pi * (95 + 110 * exp(-t * 30)) / rate
                let body = sin(phase) * exp(-t * 26)
                let click = white() * exp(-t * 900) * 0.25
                return Float((body + click) * 0.28)
            }
        case .drop:
            // A light tap, as something set down.
            let n = Int(rate * 0.07)
            return (0..<n).map { i in
                let t = Double(i) / rate
                let tone = sin(2 * .pi * 540 * t) + 0.35 * sin(2 * .pi * 1080 * t)
                return Float(tone * exp(-t * 70) * 0.09)
            }
        }
    }
}
