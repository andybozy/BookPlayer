// SPDX-License-Identifier: GPL-3.0-or-later
import Combine
import Foundation
import Network

/// Independent ABS mode. Does not initialize RevenueCat, BookPlayer Cloud or legacy CoreData.
@MainActor
public final class SelfHostedStore: ObservableObject {
  public static let shared = SelfHostedStore()
  @Published var connection: ABSConnection?
  @Published var state = ABSLocalState()
  @Published var errorMessage: String?
  @Published var busy = false
  @Published var conflicts: [String: ABSProgress?] = [:]
  @Published var downloads: [String: Double] = [:]
  @Published private var offlineReady: Set<String> = []
  @Published private var transfersRestored = false
  @Published var phoneTitle = ""
  @Published var phonePlaying = false
  @Published var phoneReachable = false
  @Published var phoneTime: Double = 0
  @Published var phoneDuration: Double = 0
  public let player = ABSPlayer()
  let downloader = ABSDownloader()
  private let keychain = KeychainService()
  private var storage: ABSLocalStore?
  private var client: ABSClient?
  private var watch: ABSWatchBridge?
  private var started = false
  private var flushing = false
  private var recordingFailure = false
  private var playGeneration = UUID()
  private var lastSync = Date.distantPast
  private let monitor = NWPathMonitor()
  private var playerSubscription: AnyCancellable?

  private init() {
    do {
      if let connection: ABSConnection = try keychain.get(.selfHostedABS) {
        try open(connection)
      }
    } catch { errorMessage = error.localizedDescription }
    player.onCheckpoint = { [weak self] book, time, finished in
      self?.checkpoint(book: book, time: time, finished: finished)
    }
    player.onError = { [weak self] error in self?.errorMessage = error.localizedDescription }
    playerSubscription = player.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    downloader.onFinished = { [weak self] task, location in self?.downloadFinished(task, location: location) }
    downloader.onError = { [weak self] task, error in
      if let task { self?.downloads.removeValue(forKey: task.bookID) }
      self?.errorMessage = error.localizedDescription
    }
    downloader.onProgress = { [weak self] task, fraction in self?.downloads[task.bookID] = fraction }
  }

  public func start() {
    guard !started else { return }
    started = true
    watch = ABSWatchBridge(store: self)
    monitor.pathUpdateHandler = { [weak self] path in
      if path.status == .satisfied {
        Task { @MainActor in await self?.flush() }
      }
    }
    monitor.start(queue: DispatchQueue(label: "BookPlayer.ABS.reachability"))
    Task { await downloader.restore(); transfersRestored = true; await refresh() }
  }

  private func open(_ value: ABSConnection) throws {
    _ = try ABSConnection.validatedServer(value.server.absoluteString)
    let disk = try ABSLocalStore(connection: value)
    let loaded = try disk.load() // Never replace a corrupt manifest with an empty library.
    storage = disk
    state = loaded
    offlineReady = Set(loaded.offline.filter { disk.complete($0.value) }.keys)
    client = ABSClient(connection: value)
    connection = value
  }

  func signIn(server: String, username: String, password: String) async {
    guard !busy else { return }
    busy = true
    errorMessage = nil
    defer { busy = false }
    do {
      let value = try await ABSClient.signIn(server: ABSConnection.validatedServer(server), username: username, password: password)
      try accept(value)
      await refresh()
    } catch { errorMessage = error.localizedDescription }
  }

  func accept(_ value: ABSConnection) throws {
    guard connection == nil || connection?.userID == value.userID && connection?.server == value.server else {
      throw ABSError.signedOut
    }
    try keychain.set(value, key: .selfHostedABS)
    try open(value)
  }

  var canSignOut: Bool { transfersRestored && state.pending.isEmpty && downloader.active.isEmpty && !flushing }
  func signOut() {
    guard canSignOut else { errorMessage = SHText("sh_pending_signout"); return }
    player.pause()
    // Pausing may have created the last checkpoint; keep it before removing access.
    guard state.pending.isEmpty else { Task { await flush() }; return }
    do {
      try keychain.remove(.selfHostedABS)
      connection = nil
      player.stop()
      client = nil
      storage = nil
      state = ABSLocalState()
      offlineReady = []
      conflicts = [:]
    } catch { errorMessage = error.localizedDescription }
  }

  public func refresh() async {
    guard let client, let connection, storage != nil else { return }
    let scope = connection
    do {
      let libraries = try await client.libraries()
      guard self.connection == scope else { return }
      state.libraries = libraries
      try persist()
      await flush()
    } catch { errorMessage = error.localizedDescription }
  }

  func refresh(libraryID: String) async {
    guard let client, let connection, storage != nil else { return }
    do {
      let books = try await client.books(libraryID: libraryID)
      guard self.connection == connection else { return }
      state.books[libraryID] = books
      try persist()
    } catch { errorMessage = error.localizedDescription }
  }

  func play(_ selected: ABSBook) async {
    guard let client, let storage else { return }
    let operation = UUID()
    playGeneration = operation
    do {
      await flush()
      if conflicts.keys.contains(selected.id) { throw ABSError.conflict }
      let book: ABSBook
      var files: [Int: URL] = [:]
      if let offline = state.offline[selected.id], storage.complete(offline) {
        if let current = try? await client.book(selected.id),
          current.tracks.map(\.contentUrl) != offline.book.tracks.map(\.contentUrl) ||
          current.tracks.map(\.metadata.size) != offline.book.tracks.map(\.metadata.size) {
          throw ABSError.incompleteDownload
        }
        book = offline.book
        for (track, filename) in offline.files { files[track] = try storage.file(filename) }
      } else {
        book = try await client.book(selected.id)
      }
      if state.pending[book.id] == nil {
        do {
          let latest = try await client.progress(book.id)
          if let latest { state.progress[book.id] = latest } else { state.progress.removeValue(forKey: book.id) }
          try persist()
        } catch {
          // Downloaded books remain usable without the server; don't mask failures for streaming.
          if files.isEmpty { throw error }
        }
      }
      guard playGeneration == operation else { return }
      let pending = state.pending[book.id]
      let previous = state.progress[book.id]
      let finished = pending?.isFinished ?? previous?.isFinished ?? false
      let position = finished ? 0 : pending?.currentTime ?? previous?.currentTime ?? 0
      try await player.load(book: book, at: position, client: client, files: files)
    } catch { errorMessage = error.localizedDescription }
  }

  private func checkpoint(book: ABSBook, time: Double, finished: Bool) {
    guard !recordingFailure, storage != nil, time.isFinite else { return }
    let previous = state.pending[book.id]
    let remote = state.progress[book.id]
    if previous == nil, let remote, abs(remote.currentTime - time) < 0.1, remote.isFinished == finished { return }
    state.pending[book.id] = ABSCheckpoint(bookID: book.id, currentTime: min(book.duration, max(0, time)),
      duration: book.duration, isFinished: finished, baseRevision: previous?.baseRevision ?? remote?.lastUpdate ?? 0)
    do { try persist() }
    catch {
      recordingFailure = true
      player.pause()
      recordingFailure = false
      errorMessage = error.localizedDescription
      return
    }
    watch?.publishPlayer()
    if !player.isPlaying || Date().timeIntervalSince(lastSync) >= 30 {
      lastSync = Date()
      Task { await flush() }
    }
  }

  public func flush() async {
    guard !flushing, let client, let connection, storage != nil else { return }
    flushing = true
    defer { flushing = false }
    for checkpoint in Array(state.pending.values) {
      guard !conflicts.keys.contains(checkpoint.bookID) else { continue }
      do {
        let remote = try await client.progress(checkpoint.bookID)
        guard self.connection == connection else { return }
        switch checkpoint.decision(remote: remote) {
        case .conflict:
          conflicts.updateValue(remote, forKey: checkpoint.bookID)
          continue
        case .upload:
          try await client.update(checkpoint)
        case .acknowledge: break
        }
        // Re-fetch the server revision. On uncertain delivery keep the checkpoint for retry.
        let acknowledged = try await client.progress(checkpoint.bookID)
        guard self.connection == connection, let acknowledged,
          checkpoint.decision(remote: acknowledged) == .acknowledge else { continue }
        state.progress[checkpoint.bookID] = acknowledged
        if state.pending[checkpoint.bookID]?.id == checkpoint.id {
          state.pending.removeValue(forKey: checkpoint.bookID)
        } else {
          state.pending[checkpoint.bookID]?.baseRevision = acknowledged.lastUpdate ?? 0
        }
        try persist()
      } catch ABSError.http(401) { errorMessage = SHText("sh_error_signin"); return }
      catch ABSError.http(let code) where code == 403 || code == 404 {
        conflicts.updateValue(nil, forKey: checkpoint.bookID)
        errorMessage = ABSError.http(code).localizedDescription
      }
      catch {
        // Durable queue remains intact; network recovery, foreground or pause retries it.
        return
      }
    }
  }

  func resolve(bookID: String, useLocal: Bool) async {
    guard conflicts.keys.contains(bookID), let client else { return }
    do {
      let remote = try await client.progress(bookID)
      if useLocal {
        state.pending[bookID]?.baseRevision = remote?.lastUpdate ?? 0
      } else {
        state.pending.removeValue(forKey: bookID)
        if let remote { state.progress[bookID] = remote } else { state.progress.removeValue(forKey: bookID) }
        if player.book?.id == bookID {
          player.pause()
          // Pause's old position must not replace the user's explicit choice.
          state.pending.removeValue(forKey: bookID)
          player.seek(remote?.currentTime ?? 0)
          state.pending.removeValue(forKey: bookID)
        }
      }
      conflicts.removeValue(forKey: bookID)
      try persist()
      await flush()
    } catch { errorMessage = error.localizedDescription }
  }

  func download(_ selected: ABSBook) async {
    guard let client, let storage else { return }
    do {
      let book = try await client.book(selected.id)
      if state.pending[book.id] == nil {
        if let progress = try await client.progress(book.id) { state.progress[book.id] = progress }
        else { state.progress.removeValue(forKey: book.id) }
      }
      let required = book.tracks.reduce(Int64(0)) { $0 + $1.metadata.size }
      let attributes = try FileManager.default.attributesOfFileSystem(forPath: storage.audio.path)
      guard let free = attributes[.systemFreeSize] as? NSNumber, free.int64Value > required + 100_000_000 else {
        throw CocoaError(.fileWriteOutOfSpace)
      }
      // A changed edition never silently reuses audio from an older manifest.
      if let old = state.offline[book.id], old.book.tracks.map(\.contentUrl) != book.tracks.map(\.contentUrl) || old.book.tracks.map(\.metadata.size) != book.tracks.map(\.metadata.size) {
        throw ABSError.incompleteDownload
      }
      if state.offline[book.id] == nil { state.offline[book.id] = ABSOfflineBook(book: book) }
      try persist()
      for track in book.tracks {
        if let name = state.offline[book.id]?.files[track.index],
          let existing = try? storage.file(name),
          let size = (try? FileManager.default.attributesOfItem(atPath: existing.path)[.size]) as? NSNumber,
          size.int64Value == track.metadata.size { continue }
        try downloader.enqueue(request: client.request(track.contentUrl), metadata:
          ABSDownloadTask(scope: storage.root.lastPathComponent, bookID: book.id, track: track.index,
            size: track.metadata.size, filename: storage.filename(book: book, track: track)))
      }
      if !isOffline(book.id) { downloads[book.id] = 0 }
    } catch { errorMessage = error.localizedDescription }
  }

  private func downloadFinished(_ task: ABSDownloadTask, location: URL) {
    defer { try? FileManager.default.removeItem(at: location) }
    guard let storage, storage.root.lastPathComponent == task.scope, state.offline[task.bookID] != nil else { return }
    do {
      let destination = try storage.file(task.filename)
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: location)
      } else { try FileManager.default.moveItem(at: location, to: destination) }
      try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
      state.offline[task.bookID]?.files[task.track] = task.filename
      try persist()
      if let offline = state.offline[task.bookID], storage.complete(offline) {
        offlineReady.insert(task.bookID)
        downloads.removeValue(forKey: task.bookID)
      }
    } catch { errorMessage = error.localizedDescription }
  }

  func isOffline(_ id: String) -> Bool {
    offlineReady.contains(id)
  }

  func removeDownload(_ id: String) async {
    guard !(player.book?.id == id && player.isPlaying), let storage else { return }
    if player.book?.id == id { player.stop() }
    await downloader.cancel(bookID: id)
    do {
      guard let offline = state.offline.removeValue(forKey: id) else { return }
      offlineReady.remove(id)
      try persist()
      for filename in offline.files.values { try FileManager.default.removeItem(at: storage.file(filename)) }
      downloads.removeValue(forKey: id)
    } catch { errorMessage = error.localizedDescription }
  }

  func cover(_ id: String) async -> Data? {
    guard let storage else { return nil }
    let path = storage.root.appendingPathComponent("cover-" + ABSLocalStore.hash(id))
    if let cached = try? Data(contentsOf: path) { return cached }
    guard let data = try? await client?.cover(id), data.count < 20_000_000 else { return nil }
    try? data.write(to: path, options: .atomic)
    return data
  }

  func details(_ selected: ABSBook) async -> ABSBook {
    if let offline = state.offline[selected.id] { return offline.book }
    return (try? await client?.book(selected.id)) ?? selected
  }

  public var carPlayBooks: [(id: String, title: String, author: String)] {
    var byID: [String: ABSBook] = [:]
    for book in state.books.values.flatMap({ $0 }) { byID[book.id] = book }
    for book in state.offline.values.map(\.book) { byID[book.id] = book }
    return byID.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
      .map { (id: $0.id, title: $0.title, author: $0.author) }
  }

  public func prepareCarPlay() async {
    await refresh()
    for library in state.libraries { await refresh(libraryID: library.id) }
  }

  public func playBook(id: String) async {
    if let book = state.offline[id]?.book ?? state.books.values.flatMap({ $0 }).first(where: { $0.id == id }) {
      await play(book)
    }
  }

  private func persist() throws { try storage?.save(state) }
  func shareWithWatch() { watch?.shareConnection() }
  func phoneCommand(_ command: String) { watch?.command(command) }
  public func handleBackgroundSession(_ identifier: String, completion: @escaping () -> Void) {
    guard identifier == ABSDownloader.identifier else { completion(); return }
    downloader.completionHandler = completion
  }
}
