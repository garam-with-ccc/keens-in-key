import Foundation
import AVFoundation
import SwiftUI
import KeensInKeyCore

/// Simple audio preview player.
@Observable
final class Player: NSObject, AVAudioPlayerDelegate {
    private(set) var currentTrackId: UUID?
    private(set) var isPlaying = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var volume: Float = 0.9 { didSet { player?.volume = volume } }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ track: Track, autoplay: Bool = false) {
        if currentTrackId == track.id, player != nil {
            if autoplay { play() }
            return
        }
        stopTimer()
        player?.stop()
        player = nil
        currentTrackId = track.id
        currentTime = 0
        duration = track.result?.duration ?? track.duration ?? 0
        isPlaying = false
        do {
            let p = try AVAudioPlayer(contentsOf: track.url)
            p.delegate = self
            p.volume = volume
            p.prepareToPlay()
            player = p
            duration = p.duration
            if autoplay { play() }
        } catch {
            NSLog("Player failed: \(error)")
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
        currentTime = player?.currentTime ?? currentTime
    }

    func toggle() { isPlaying ? pause() : play() }

    func stop() {
        player?.stop()
        player?.currentTime = 0
        isPlaying = false
        currentTime = 0
        stopTimer()
    }

    func seek(to time: Double) {
        guard let player else { currentTime = time; return }
        let t = max(0, min(time, max(0, player.duration - 0.05)))
        player.currentTime = t
        currentTime = t
        if isPlaying, !player.isPlaying { player.play() }
    }

    func unload() {
        stop()
        player = nil
        currentTrackId = nil
        duration = 0
    }

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimer()
        currentTime = 0
    }
}
