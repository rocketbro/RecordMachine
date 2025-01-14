//
//  AudioPlayerManager.swift
//  RecordMachine
//
//  Created by Asher Pope on 10/21/24.
//  To whoever has to go through this file one day,
//  I am so sorry. Good luck.
//

import SwiftUI
import AVFoundation
import MediaPlayer

@Observable final class AudioManager: NSObject, Sendable, AVAudioPlayerDelegate {
    private var audioPlayer: AVAudioPlayer?
    var showingPlayer: Bool = false
    private var _currentFileLength: Double = 0
    var currentFileLength: Double {
        get { _currentFileLength }
    }
    var currentFileName: String = "Import an audio file below"
    var currentTrack: Track?
    var queue: [Track] = []
    var isPlaying: Bool = false
    var showFullPlayer: Bool = false
    
    var sheetBinding: Binding<Bool> {
        Binding(
            get: { self.showFullPlayer },
            set: { self.showFullPlayer = $0 }
        )
    }
    
    private var _audioPlayerCurrentTime: Double = 0
    var audioPlayerCurrentTime: Double {
        get { _audioPlayerCurrentTime }
    }
    
    private var isObserving: Bool = false
    private var observationTask: Task<Void, Never>?
    
    private let rewindTimer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()
    private var shouldSkipBackward: Bool = false
    
    override init() {
        super.init()
        setupRemoteControls()
        setupAudioSession()
    }
    
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    private func setupRemoteControls() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play/Pause command
        commandCenter.playCommand.addTarget { [weak self] _ in
            if !(self?.isPlaying ?? true) {
                self?.playPause()
                return .success
            }
            return .commandFailed
        }
        
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            if self?.isPlaying ?? false {
                self?.playPause()
                return .success
            }
            return .commandFailed
        }
        
        // Skip forward command
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.skipToNext()
            return .success
        }
        
        // Skip backward command
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.rewindButton()
            return .success
        }
        
        // Seek command
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  let player = self?.audioPlayer else {
                return .commandFailed
            }
            player.currentTime = event.positionTime
            self?.updateNowPlayingData()
            return .success
        }
    }
    
    private func processArtwork(_ image: UIImage) -> UIImage {
        print("Original image orientation: \(image.imageOrientation.rawValue)")

        // First make the image square by cropping to center
        let squareImage: UIImage
        if image.size.width != image.size.height {
            let size = min(image.size.width, image.size.height)
            let x = (image.size.width - size) / 2
            let y = (image.size.height - size) / 2
            let square = CGRect(x: x, y: y, width: size, height: size)
            
            if let cgImage = image.cgImage?.cropping(to: square) {
                // If original was .down (3), convert to .up (0)
                let orientation = image.imageOrientation.rawValue == 3 ? .up : image.imageOrientation
                print("Middle image orientation: \(orientation.rawValue)")
                squareImage = UIImage(cgImage: cgImage, scale: image.scale, orientation: orientation)
            } else {
                squareImage = image
            }
        } else {
            squareImage = image
        }
        
        // Convert image to sRGB color space if needed
        var srgbImage: UIImage
        if squareImage.cgImage?.colorSpace?.name == CGColorSpace.displayP3 {
            UIGraphicsBeginImageContextWithOptions(squareImage.size, false, squareImage.scale)
            squareImage.draw(at: .zero)
            let newImage = UIGraphicsGetImageFromCurrentImageContext() ?? squareImage
            UIGraphicsEndImageContext()
            srgbImage = UIImage(cgImage: newImage.cgImage!, scale: newImage.scale, orientation: squareImage.imageOrientation)
        } else {
            srgbImage = squareImage
        }
        
        let targetSize = CGSize(width: 1024, height: 1024)
        
        UIGraphicsBeginImageContextWithOptions(targetSize, false, 1.0)
        srgbImage.draw(in: CGRect(origin: .zero, size: targetSize))
        let processedImage = UIGraphicsGetImageFromCurrentImageContext() ?? srgbImage
        UIGraphicsEndImageContext()
        
        // Preserve original orientation unless it was .down
        if let finalCGImage = processedImage.cgImage {
            let finalOrientation = image.imageOrientation == .down ? .up : image.imageOrientation
            print("Final image orientation: \(finalOrientation.rawValue)")
            return UIImage(cgImage: finalCGImage, scale: processedImage.scale, orientation: finalOrientation)
        }
        
        return processedImage
    }
    
    func updateNewTrackData() {
        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        
        var nowPlayingInfo = [String: Any]()
        
        // Basic metadata
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        nowPlayingInfo[MPMediaItemPropertyArtist] = track.album?.artist ?? "Unknown Artist"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = track.album?.title ?? "Unknown Album"
        
        // Add artwork if available
        if let artworkData = track.album?.artwork,
           let artworkImage = UIImage(data: artworkData) {
            let processedImage = processArtwork(artworkImage)
            let artwork = MPMediaItemArtwork(boundsSize: processedImage.size) { _ in
                return processedImage
            }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
        }
        
        // Playback information
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = currentFileLength
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        _audioPlayerCurrentTime = self.audioPlayer?.currentTime ?? 0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func updateNowPlayingData() {
        guard let track = currentTrack else {
            return
        }
        
        var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
        
        nowPlayingInfo[MPMediaItemPropertyTitle] = track.title
        // Use the stored length instead of querying the player
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = _currentFileLength
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer?.currentTime ?? 0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        
        _audioPlayerCurrentTime = self.audioPlayer?.currentTime ?? 0
        
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }
    
    func loadQueue(for album: Album) {
        if album.trackListing.count != 0 {
            var queue: [Track] = []
            for track in album.trackListing.sorted(by: { $0.index < $1.index }) {
                queue.append(track)
                print(track.title)
            }
            
            self.queue = queue
            self.currentTrack = queue.first
            prepareAudioPlayer()
        }
    }
    
    func playTrack(_ track: Track) {
        resetPlayer()
        let tracklist = track.album!.trackListing.sorted(by: { $0.index < $1.index })
        self.queue = tracklist
        self.currentTrack = queue[queue.firstIndex(of: track) ?? 0]
        prepareAudioPlayer()
        
        guard let _ = currentTrack?.audioUrl else {
            stopAudioPlayer()
            return
        }
        guard let audioPlayer = audioPlayer else { return }
        audioPlayer.play()
        self.isPlaying = true

    }
    
    func playPause() {
        if let audioPlayer = audioPlayer {
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                isPlaying = false
            } else {
                audioPlayer.play()
                isPlaying = true
            }
            updateNewTrackData()
        } else {
            print("Audio player is nil")
        }
    }
    
    func skipToNext() {
        guard !queue.isEmpty else { return }
        guard let currentTrack = currentTrack else { return }
        
        // If we're at the last track, loop back to start
        if currentTrack == queue.last {
            self.currentTrack = queue.first
            stopAudioPlayer()
            restartTrack()
            return
        }
        
        // Move to next track
        let nextIndex = queue.firstIndex(of: currentTrack)! + 1
        self.currentTrack = queue[nextIndex]
        self.prepareAudioPlayer()
    }
    
    func rewindToPrevious() {
        if queue.count != 0 {
            if currentTrack != queue.first {
                if let oldTrack = currentTrack {
                    currentTrack = queue[queue.firstIndex(of: oldTrack)! - 1]
                    prepareAudioPlayer()
                }
            }
        }
    }
    
    func restartTrack() {
        guard let audioPlayer = audioPlayer else {
            print("Audio player is nil.")
            return
        }
        
        audioPlayer.currentTime = 0
    }
    
    func rewindButton() {
        Task {
            if isPlaying {
                if shouldSkipBackward {
                    rewindToPrevious()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    shouldSkipBackward = false
                } else {
                    restartTrack()
                    shouldSkipBackward = true
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    shouldSkipBackward = false
                }
            } else {
                guard let audioPlayer = audioPlayer else {
                    rewindToPrevious()
                    return
                }
                
                if audioPlayer.currentTime != 0 {
                    restartTrack()
                } else {
                    rewindToPrevious()
                }
            }
        }
        
    }
    
    func stopAudioPlayer() {
        guard let audioPlayer = audioPlayer else {
            print("Audio player is nil.")
            return
        }
        audioPlayer.stop()
        isPlaying = false
        updateNewTrackData()
    }
    
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        if flag {
            print("Audio finished playing successfully")
            skipToNext()
            // Trigger any additional action here
        } else {
            print("Playback finished due to an error")
        }
    }
    
    func resetPlayer() {
        audioPlayer?.stop()
        audioPlayer?.currentTime = 0
        isPlaying = false
        _currentFileLength = 0
        currentFileName = "Import an audio file below"
        updateNewTrackData()
    }
    
    func prepareAudioPlayer() {
        guard let track = currentTrack else {
            self.resetPlayer()
            print("No track selected")
            return
        }
        
        // First try the stored URL
        let storedUrl = track.audioUrl
        
        // Then try to reconstruct the URL from the filename
        let filename = storedUrl?.lastPathComponent ?? "\(track.title).m4a" // or whatever extension you use
        guard let validUrl = storedUrl.flatMap({ FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
                ?? DocumentsManager.getFileUrl(filename: filename) else {
            self.resetPlayer()
            print("\(track.title) audio file not found in documents directory.")
            return
        }
        
        // Update the model with the valid URL
        track.audioUrl = validUrl
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: validUrl)
            audioPlayer?.delegate = self
            audioPlayer?.prepareToPlay()
            _currentFileLength = audioPlayer?.duration ?? 0
            currentFileName = validUrl.lastPathComponent
            
            // Start observing playback progress for updating now playing info
            updateNewTrackData()
            startPlaybackObservation()
            
            guard let audioPlayer = audioPlayer else {
                return
            }
            
            if isPlaying {
                if currentTrack?.audioUrl != nil {
                    audioPlayer.play()
                } else {
                    audioPlayer.stop()
                    isPlaying = false
                }
            }
        } catch {
            print("Error creating audio player: \(error.localizedDescription)")
            track.audioUrl = nil
        }
    }
    
    private func startPlaybackObservation() {
        guard !isObserving else { return }
        isObserving = true
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isObserving {
                self.updateNowPlayingData()
                // Changed sleep duration from 500ms to 250ms for smoother updates
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
    
    func stopObservation() {
        isObserving = false
        observationTask?.cancel()
        observationTask = nil
    }
    
    deinit {
        stopObservation()
    }
}

extension AudioManager {
    func seek(to time: Double) {
        audioPlayer?.currentTime = time
        updateNowPlayingData()
    }
}
