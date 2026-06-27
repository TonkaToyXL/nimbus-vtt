import AVFoundation

class SoundManager {
    static let shared = SoundManager()

    private var startPlayer: AVAudioPlayer?
    private var stopPlayer: AVAudioPlayer?
    private var donePlayer: AVAudioPlayer?

    var volume: Float = 0.7

    private init() {
        startPlayer = load("start")
        stopPlayer = load("stop")
        donePlayer = load("done")
    }

    private func load(_ name: String) -> AVAudioPlayer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "wav") else {
            VTTLogger.log("sound missing", ["name": name])
            return nil
        }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        player?.volume = volume
        return player
    }

    func setVolume(_ vol: Float) {
        volume = vol
        startPlayer?.volume = vol
        stopPlayer?.volume = vol
        donePlayer?.volume = vol
    }

    func playStart() {
        DispatchQueue.main.async {
            self.startPlayer?.currentTime = 0
            self.startPlayer?.play()
        }
    }

    func playStop() {
        DispatchQueue.main.async {
            self.stopPlayer?.currentTime = 0
            self.stopPlayer?.play()
        }
    }

    func playDone() {
        DispatchQueue.main.async {
            self.donePlayer?.currentTime = 0
            self.donePlayer?.play()
        }
    }
}
