// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Account-scoped, atomic manifests. Audio is never treated as complete before validation.
@MainActor
final class ABSLocalStore {
  let root: URL
  let audio: URL
  private let manifest: URL

  init(connection: ABSConnection) throws {
    let fm = FileManager.default
    guard let applicationSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
      throw CocoaError(.fileNoSuchFile)
    }
    let scope = Self.hash(connection.server.absoluteString + "|" + connection.userID)
    root = applicationSupport.appendingPathComponent("SelfHostedABS/\(scope)", isDirectory: true)
    audio = root.appendingPathComponent("Audio", isDirectory: true)
    manifest = root.appendingPathComponent("state-v1.json")
    try fm.createDirectory(at: audio, withIntermediateDirectories: true)
    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: root.path)
    try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: audio.path)
    var audioURL = audio
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try audioURL.setResourceValues(values)
  }

  static func hash(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  func load() throws -> ABSLocalState {
    guard FileManager.default.fileExists(atPath: manifest.path) else { return ABSLocalState() }
    return try JSONDecoder().decode(ABSLocalState.self, from: Data(contentsOf: manifest))
  }

  func save(_ state: ABSLocalState) throws {
    try JSONEncoder().encode(state).write(to: manifest, options: .atomic)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: manifest.path)
  }

  func filename(book: ABSBook, track: ABSTrack) -> String {
    let ext = (track.metadata.filename as NSString).pathExtension.lowercased()
    let safeExtension = ["mp3", "m4b", "m4a", "mp4", "aac", "flac", "ogg", "opus", "wav"].contains(ext) ? ext : "audio"
    return Self.hash(book.id) + "-\(track.index)." + safeExtension
  }

  func file(_ name: String) throws -> URL {
    guard name == (name as NSString).lastPathComponent, !name.isEmpty, name != ".", name != ".." else {
      throw ABSError.unsafeResource
    }
    return audio.appendingPathComponent(name)
  }

  func complete(_ offline: ABSOfflineBook) -> Bool {
    guard !offline.book.tracks.isEmpty else { return false }
    return offline.book.tracks.allSatisfy { track in
      guard let filename = offline.files[track.index], let url = try? file(filename),
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
        let size = attributes[.size] as? NSNumber else { return false }
      return size.int64Value == track.metadata.size
    }
  }
}
