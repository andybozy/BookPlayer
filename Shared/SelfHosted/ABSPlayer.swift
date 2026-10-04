// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Combine
import MediaPlayer

@MainActor
public final class ABSPlayer: ObservableObject {
  @Published var book: ABSBook?
  @Published var currentTime: Double = 0
  @Published var isPlaying = false
  @Published var rate: Float = 1
  @Published var sleepDeadline: Date?
  var onCheckpoint: ((ABSBook, Double, Bool) -> Void)?
  var onError: ((Error) -> Void)?
  private let player = AVPlayer()
  private var observer: Any?
  private var endObserver: NSObjectProtocol?
  private var interruptionObserver: NSObjectProtocol?
  private var routeObserver: NSObjectProtocol?
  private var statusObserver: NSKeyValueObservation?
  private var timeControlObserver: NSKeyValueObservation?
  private var stream: ABSStreamLoader?
  private var client: ABSClient?
  private var files: [Int: URL] = [:]
  private var trackIndex = 0
  private var generation = UUID()
  private var seeking = false
  private var finished = false
  private var lastCheckpoint = Date.distantPast
  private var sleepTask: Task<Void, Never>?

  public convenience init() { self.init(registerRemoteCommands: true) }

  init(registerRemoteCommands: Bool) {
    observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
      Task { @MainActor in self?.tick(time) }
    }
    timeControlObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
      Task { @MainActor in self?.isPlaying = player.timeControlStatus == .playing }
    }
    if registerRemoteCommands { configureCommands() }
    interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.pause() }
    }
    routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
      if (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        Task { @MainActor in self?.pause() }
      }
    }
  }

  func load(book: ABSBook, at time: Double, client: ABSClient, files: [Int: URL]) async throws {
    pause()
    try book.validateAudio()
    player.replaceCurrentItem(with: nil)
    stream?.invalidate()
    stream = nil
    self.book = book
    self.client = client
    self.files = files
    finished = false
    currentTime = min(max(0, time), max(0, book.duration - 0.1))
    generation = UUID()
    let loadGeneration = generation
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio, options: [])
    #if os(watchOS)
    try await audioSession.activate()
    #else
    try audioSession.setActive(true)
    #endif
    guard generation == loadGeneration else { return }
    try selectTrack(at: currentTime, play: true)
  }

  private func selectTrack(at time: Double, play: Bool) throws {
    guard let book, let client else { return }
    generation = UUID()
    finished = false
    let operation = generation
    seeking = true
    player.pause()
    player.replaceCurrentItem(with: nil)
    isPlaying = false
    currentTime = time
    trackIndex = book.tracks.lastIndex(where: { $0.startOffset <= time }) ?? 0
    let track = book.tracks[trackIndex]
    stream?.invalidate()
    stream = nil
    let item: AVPlayerItem
    if let local = files[track.index] {
      item = AVPlayerItem(url: local)
    } else {
      let loader = try ABSStreamLoader(request: client.request(track.contentUrl))
      stream = loader
      item = AVPlayerItem(asset: loader.asset)
    }
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.generation == operation else { return }
        self.trackEnded()
      }
    }
    statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      if item.status == .failed {
        Task { @MainActor in
          guard let self, self.generation == operation else { return }
          self.pause()
          self.onError?(item.error ?? ABSError.noAudio)
        }
      }
    }
    player.replaceCurrentItem(with: item)
    player.seek(to: CMTime(seconds: max(0, time - track.startOffset), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
      Task { @MainActor in
        guard let self, self.generation == operation else { return }
        self.seeking = false
        if success && play { self.player.playImmediately(atRate: self.rate) }
        self.updateNowPlaying()
      }
    }
  }

  public func toggle() { isPlaying ? pause() : resume() }
  public func resume() {
    guard book != nil else { return }
    Task {
      do {
        #if os(watchOS)
        try await AVAudioSession.sharedInstance().activate()
        #else
        try AVAudioSession.sharedInstance().setActive(true)
        #endif
        if finished || player.currentItem == nil {
          try selectTrack(at: finished ? 0 : currentTime, play: true)
          checkpoint()
        } else {
          player.playImmediately(atRate: rate)
        }
        updateNowPlaying()
      } catch { onError?(error) }
    }
  }
  public func pause() {
    player.pause()
    isPlaying = false
    checkpoint()
    updateNowPlaying()
  }
  public func stop() {
    pause()
    generation = UUID()
    player.replaceCurrentItem(with: nil)
    stream?.invalidate()
    stream = nil
    book = nil
    files = [:]
    sleep(after: nil)
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
  public func skip(_ seconds: Double) { seek(currentTime + seconds) }
  func seek(_ time: Double) {
    guard let book else { return }
    guard time.isFinite else { onError?(ABSError.invalidResponse); return }
    do {
      try selectTrack(at: min(max(0, time), max(0, book.duration - 0.05)), play: isPlaying)
      checkpoint()
    } catch { onError?(error) }
  }
  func setRate(_ value: Float) {
    rate = min(3, max(0.5, value))
    if isPlaying { player.rate = rate }
    updateNowPlaying()
  }
  func sleep(after minutes: Int?) {
    sleepTask?.cancel()
    sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0 * 60)) }
    guard let minutes else { return }
    sleepTask = Task { [weak self] in
      do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60_000_000_000) }
      catch { return }
      self?.pause()
      self?.sleepDeadline = nil
    }
  }
  private func tick(_ time: CMTime) {
    guard !seeking, let book, book.tracks.indices.contains(trackIndex), time.seconds.isFinite else { return }
    currentTime = min(book.duration, book.tracks[trackIndex].startOffset + max(0, time.seconds))
    if isPlaying && Date().timeIntervalSince(lastCheckpoint) >= 5 { checkpoint() }
    updateNowPlaying()
  }
  private func checkpoint() {
    guard let book else { return }
    lastCheckpoint = Date()
    onCheckpoint?(book, currentTime, finished)
  }
  private func trackEnded() {
    guard let book else { return }
    if book.tracks.indices.contains(trackIndex + 1) {
      do { try selectTrack(at: book.tracks[trackIndex + 1].startOffset, play: true) }
      catch { onError?(error) }
    } else {
      player.pause()
      isPlaying = false
      currentTime = book.duration
      finished = true
      checkpoint()
      updateNowPlaying()
    }
  }
  private func updateNowPlaying() {
    guard let book else { return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: book.title, MPMediaItemPropertyArtist: book.author,
      MPMediaItemPropertyPlaybackDuration: book.duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
      MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
    ]
  }
  private func configureCommands() {
    let commands = MPRemoteCommandCenter.shared()
    commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
    commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
    commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }
    commands.skipForwardCommand.preferredIntervals = [30]
    commands.skipBackwardCommand.preferredIntervals = [15]
    commands.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(30) }; return .success }
    commands.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-15) }; return .success }
    commands.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      Task { @MainActor in self?.seek(event.positionTime) }
      return .success
    }
  }
}
