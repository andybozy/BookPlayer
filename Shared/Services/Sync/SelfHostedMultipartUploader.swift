import Combine
import Foundation

/// Uses the original background transfer sessions. Only one 8 MiB part is staged on disk at a time.
/// The sync queue owns retries; the upload ID survives termination and S3 confirms received parts.
final class SelfHostedMultipartUploader {
  static let partSize = 8 * 1024 * 1024
  static let maximumFileSize: Int64 = 10 * 1024 * 1024 * 1024
  let client: NetworkClientProtocol
  let uuid: String
  let relativePath: String
  private let transferLock = NSLock()
  private var activeTransfer: URLSessionTask?
  private var currentTask: URLSessionTask? {
    get { transferLock.lock(); defer { transferLock.unlock() }; return activeTransfer }
    set { transferLock.lock(); defer { transferLock.unlock() }; activeTransfer = newValue }
  }

  struct State: Codable {
    let uploadId: String
    let fileSize: Int64
    let modified: Date
    let accountId: String
  }
  struct Start: Decodable { let status: String; let uploadId: String?; let partCount: Int? }
  struct UploadedParts: Decodable {
    struct Part: Decodable { let partNumber: Int; let size: Int64 }
    let parts: [Part]
  }
  struct SignedParts: Decodable {
    struct Part: Decodable { let partNumber: Int; let url: URL }
    let parts: [Part]
  }
  struct Complete: Decodable { let synced: Bool }

  init(client: NetworkClientProtocol, uuid: String, relativePath: String) {
    self.client = client
    self.uuid = uuid
    self.relativePath = relativePath
  }

  func cancel() { currentTask?.cancel() }

  static func partCount(for size: Int64) throws -> Int {
    guard size > 0, size <= maximumFileSize else {
      throw BookPlayerError.runtimeError("self_hosted_file_size_error".localized)
    }
    return Int((size + Int64(partSize) - 1) / Int64(partSize))
  }

  func upload(file: URL) async throws {
    guard AppEnvironment.isSelfHosted, UUID(uuidString: uuid) != nil else {
      throw AccountError.missingToken
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    let modified = attributes[.modificationDate] as? Date ?? .distantPast
    let count = try Self.partCount(for: size)
    let identity: SelfHostedSession = try await client.request(path: "/v1/user/session", method: .get, parameters: nil)
    guard identity.selfHosted, UUID(uuidString: identity.accountId) != nil else { throw AccountError.missingToken }
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
      .appendingPathComponent("PersonalUploads", isDirectory: true)
      .appendingPathComponent(identity.accountId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stateURL = directory.appendingPathComponent(uuid + ".json")
    let partURL = directory.appendingPathComponent(uuid + ".part")
    var state = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) }
    if state?.fileSize != size || state?.modified != modified || state?.accountId != identity.accountId {
      state = nil
    }
    var received: [Int: Int64] = [:]
    if let saved = state {
      do {
        let parts: UploadedParts = try await client.request(path: "/v1/library/upload/parts", method: .get,
          parameters: ["uuid": uuid, "uploadId": saved.uploadId])
        for part in parts.parts { received[part.partNumber] = part.size }
      } catch BookPlayerError.networkErrorWithCode(_, let code) where code == "upload_not_found" {
        state = nil
      }
    }
    if state == nil {
      let start: Start = try await client.request(path: "/v1/library/upload/start", method: .post,
        parameters: ["uuid": uuid, "fileSize": size, "partSize": Self.partSize])
      if start.status == "exists" {
        try? FileManager.default.removeItem(at: stateURL)
        try? FileManager.default.removeItem(at: partURL)
        return
      }
      guard start.status == "started", let uploadId = start.uploadId, start.partCount == count else {
        throw URLError(.badServerResponse)
      }
      let fresh = State(uploadId: uploadId, fileSize: size, modified: modified, accountId: identity.accountId)
      try JSONEncoder().encode(fresh).write(to: stateURL, options: .atomic)
      state = fresh
    }
    guard let state else { throw URLError(.badServerResponse) }
    let input = try FileHandle(forReadingFrom: file)
    defer { try? input.close() }
    for number in 1...count {
      try Task.checkCancellation()
      let offset = Int64(number - 1) * Int64(Self.partSize)
      let length = Int(min(Int64(Self.partSize), size - offset))
      if received[number] != Int64(length) {
        try input.seek(toOffset: UInt64(offset))
        let data = try input.read(upToCount: length) ?? Data()
        guard data.count == length else { throw URLError(.cannotReadFromFile) }
        // Atomic replacement leaves a previous OS background task's open inode intact.
        try data.write(to: partURL, options: .atomic)
        var lastError: Error?
        for attempt in 0..<3 {
          do {
            try Task.checkCancellation()
            let signed: SignedParts = try await client.request(path: "/v1/library/upload/parts", method: .post,
              parameters: ["uuid": uuid, "uploadId": state.uploadId, "partNumbers": [number]])
            guard let part = signed.parts.first, part.partNumber == number, part.url.scheme == "https" else {
              throw URLError(.badServerResponse)
            }
            try await sendPart(file: partURL, url: part.url, name: "multipart:\(uuid):\(state.uploadId):\(number)")
            lastError = nil
            break
          } catch {
            try Task.checkCancellation()
            lastError = error
            if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(1 << attempt) * 1_000_000_000) }
          }
        }
        if let lastError { throw lastError }
      }
      NotificationCenter.default.post(name: .uploadProgressUpdated, object: nil, userInfo: [
        "uuid": uuid, "relativePath": relativePath, "progress": Double(number) / Double(count)
      ])
    }
    let finalAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    guard finalAttributes[.modificationDate] as? Date == modified,
          (finalAttributes[.size] as? NSNumber)?.int64Value == size else {
      throw URLError(.cannotReadFromFile)
    }
    let completed: Complete = try await client.request(path: "/v1/library/upload/complete", method: .post,
      parameters: ["uuid": uuid, "uploadId": state.uploadId, "fileSize": size, "partCount": count])
    guard completed.synced else { throw URLError(.badServerResponse) }
    try? FileManager.default.removeItem(at: stateURL)
    try? FileManager.default.removeItem(at: partURL)
  }

  private func sendPart(file: URL, url: URL, name: String) async throws {
    let session = UserDefaults.standard.bool(forKey: Constants.UserDefaults.allowCellularData)
      ? BPURLSession.shared.backgroundCellularSession : BPURLSession.shared.backgroundSession
    var subscriber: AnyCancellable?
    let completion = AsyncThrowingStream<Bool, Error> { continuation in
      subscriber = BPURLSession.shared.completionPublisher.sink { task, error in
        guard task.taskDescription == name else { return }
        if let error { continuation.finish(throwing: error) } else {
          continuation.yield(true)
          continuation.finish()
        }
      }
    }
    defer { subscriber?.cancel(); currentTask = nil }
    let task = await client.uploadTask(file, remoteURL: url, taskDescription: name, session: session)
    currentTask = task
    try await withTaskCancellationHandler {
      try Task.checkCancellation()
      task.resume()
      for try await _ in completion { break }
      try Task.checkCancellation()
    } onCancel: { task.cancel() }
  }
}

struct SelfHostedLibraryStatus: Decodable {
  let unknown: [String]
  let unsynced: [String]
}
