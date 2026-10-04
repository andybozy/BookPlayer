// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum SelfHostedConfiguration {
  public static var enabled: Bool {
    Bundle.main.object(forInfoDictionaryKey: "BPSelfHosted") as? String == "YES"
  }
  public static var defaultServer: String {
    Bundle.main.object(forInfoDictionaryKey: "BPABSServer") as? String ?? ""
  }
}

struct ABSConnection: Codable, Equatable, Sendable {
  let server: URL
  let userID: String
  let username: String
  let token: String

  static func validatedServer(_ text: String) throws -> URL {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      url.scheme?.lowercased() == "https", url.host != nil,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/"
    else { throw ABSError.invalidServer }
    return url
  }

  static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
    lhs.scheme?.lowercased() == rhs.scheme?.lowercased() &&
      lhs.host?.lowercased() == rhs.host?.lowercased() &&
      (lhs.port ?? 443) == (rhs.port ?? 443)
  }

  func resourceURL(_ path: String) throws -> URL {
    guard let url = URL(string: path, relativeTo: server)?.absoluteURL,
      Self.sameOrigin(server, url), url.user == nil, url.password == nil,
      url.fragment == nil, url.query == nil
    else { throw ABSError.unsafeResource }
    return url
  }
}

enum ABSError: LocalizedError {
  case invalidServer, unsafeResource, invalidResponse, http(Int), noAudio, incompleteDownload, conflict, signedOut
  var errorDescription: String? {
    switch self {
    case .invalidServer: return SHText("sh_error_server")
    case .unsafeResource: return SHText("sh_error_origin")
    case .invalidResponse: return SHText("sh_error_response")
    case .http(let code): return String(format: SHText("sh_error_http"), code)
    case .noAudio: return SHText("sh_error_audio")
    case .incompleteDownload: return SHText("sh_error_download")
    case .conflict: return SHText("sh_conflict_explanation")
    case .signedOut: return SHText("sh_error_signin")
    }
  }
}

func SHText(_ key: String) -> String {
  NSLocalizedString(key, bundle: .main, comment: "Self-hosted Audiobookshelf")
}

struct ABSLibrary: Codable, Identifiable, Sendable {
  let id: String
  let name: String
  let mediaType: String
}

struct ABSBook: Codable, Identifiable, Sendable {
  let id: String
  let libraryId: String
  let media: Media
  let isMissing: Bool?
  let isInvalid: Bool?
  struct Media: Codable, Sendable {
    let metadata: Metadata
    let duration: Double?
    let size: Int64?
    let tracks: [ABSTrack]?
    let chapters: [ABSChapter]?
    let coverPath: String?
  }
  struct Metadata: Codable, Sendable {
    let title: String?
    let authorName: String?
    let narratorName: String?
    let seriesName: String?
    let descriptionPlain: String?
    let language: String?
    let publishedYear: String?
    let abridged: Bool?
  }
  var title: String { media.metadata.title ?? id }
  var author: String { media.metadata.authorName ?? "" }
  var duration: Double { max(0, media.duration ?? 0) }
  var tracks: [ABSTrack] { (media.tracks ?? []).sorted { $0.startOffset < $1.startOffset } }
  var chapters: [ABSChapter] { media.chapters ?? [] }
  var searchableText: String {
    [title, author, media.metadata.narratorName ?? "", media.metadata.seriesName ?? ""].joined(separator: " ")
  }
  func validateAudio() throws {
    guard isMissing != true, isInvalid != true, duration.isFinite, duration > 0, !tracks.isEmpty,
      Set(tracks.map(\.index)).count == tracks.count,
      tracks.allSatisfy({ $0.duration.isFinite && $0.duration > 0 && $0.startOffset.isFinite &&
        $0.startOffset >= 0 && $0.metadata.size > 0 })
    else { throw ABSError.noAudio }
    var expectedOffset: Double = 0
    for track in tracks {
      guard abs(track.startOffset - expectedOffset) < 0.1 else { throw ABSError.noAudio }
      expectedOffset += track.duration
    }
    guard abs(expectedOffset - duration) < 1 else { throw ABSError.noAudio }
  }
}

struct ABSTrack: Codable, Identifiable, Sendable {
  let index: Int
  let startOffset: Double
  let duration: Double
  let contentUrl: String
  let mimeType: String?
  let metadata: FileMetadata
  var id: Int { index }
  struct FileMetadata: Codable, Sendable {
    let filename: String
    let size: Int64
  }
}

struct ABSChapter: Codable, Identifiable, Sendable {
  let id: Int
  let start: Double
  let end: Double
  let title: String
}

struct ABSProgress: Codable, Sendable {
  let currentTime: Double
  let duration: Double
  let isFinished: Bool
  let lastUpdate: Double?
}

struct ABSCheckpoint: Codable, Identifiable, Sendable {
  var id = UUID()
  let bookID: String
  let currentTime: Double
  let duration: Double
  let isFinished: Bool
  var baseRevision: Double

  enum Decision: Equatable { case upload, acknowledge, conflict }
  func decision(remote: ABSProgress?) -> Decision {
    guard let remote else { return baseRevision > 0 ? .conflict : .upload }
    if abs(remote.currentTime - currentTime) < 0.5 && remote.isFinished == isFinished {
      return .acknowledge
    }
    // Compare revisions, never the furthest position. Intentional rewinds are valid.
    return (remote.lastUpdate ?? 0) > baseRevision ? .conflict : .upload
  }
}

struct ABSOfflineBook: Codable, Sendable {
  let book: ABSBook
  var files: [Int: String] = [:]
}

struct ABSLocalState: Codable {
  var libraries: [ABSLibrary] = []
  var books: [String: [ABSBook]] = [:]
  var offline: [String: ABSOfflineBook] = [:]
  var progress: [String: ABSProgress] = [:]
  var pending: [String: ABSCheckpoint] = [:]
}
