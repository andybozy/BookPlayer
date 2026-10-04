// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ABSDownloadTask: Codable, Sendable {
  let scope: String
  let bookID: String
  let track: Int
  let size: Int64
  let filename: String
}

/// Background transfers survive suspension. Manifests contain no credentials.
@MainActor
final class ABSDownloader: NSObject, URLSessionDownloadDelegate {
  static var identifier: String { (Bundle.main.bundleIdentifier ?? "BookPlayer") + ".abs.offline" }
  var completionHandler: (() -> Void)?
  var onFinished: ((ABSDownloadTask, URL) -> Void)?
  var onError: ((ABSDownloadTask?, Error) -> Void)?
  var onProgress: ((ABSDownloadTask, Double) -> Void)?
  private var session: URLSession!
  private(set) var active: [Int: ABSDownloadTask] = [:]

  override init() {
    super.init()
    let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    configuration.sessionSendsLaunchEvents = true
    configuration.isDiscretionary = false
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.allowsCellularAccess = false
    configuration.httpCookieStorage = nil
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 1
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
  }

  func restore() async {
    let tasks = await session.allTasks
    active = Dictionary(uniqueKeysWithValues: tasks.compactMap { task in
      guard let value = Self.metadata(task) else { return nil }
      return (task.taskIdentifier, value)
    })
  }

  func enqueue(request: URLRequest, metadata: ABSDownloadTask) throws {
    guard !active.values.contains(where: { $0.scope == metadata.scope && $0.bookID == metadata.bookID && $0.track == metadata.track }) else { return }
    let data = try JSONEncoder().encode(metadata)
    let task = session.downloadTask(with: request)
    task.taskDescription = String(data: data, encoding: .utf8)
    active[task.taskIdentifier] = metadata
    task.resume()
  }

  func cancel(bookID: String) async {
    for task in await session.allTasks where Self.metadata(task)?.bookID == bookID {
      task.cancel()
    }
  }

  nonisolated private static func metadata(_ task: URLSessionTask) -> ABSDownloadTask? {
    guard let text = task.taskDescription else { return nil }
    return try? JSONDecoder().decode(ABSDownloadTask.self, from: Data(text.utf8))
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                             didFinishDownloadingTo location: URL) {
    let metadata = Self.metadata(downloadTask)
    do {
      guard let metadata, let response = downloadTask.response as? HTTPURLResponse,
        response.statusCode == 200,
        let size = try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber,
        size.int64Value == metadata.size else { throw ABSError.incompleteDownload }
      // URLSession deletes `location` on return: move it synchronously first.
      let staged = FileManager.default.temporaryDirectory.appendingPathComponent("abs-" + UUID().uuidString)
      try FileManager.default.moveItem(at: location, to: staged)
      DispatchQueue.main.async { [weak self] in
        guard let self else { try? FileManager.default.removeItem(at: staged); return }
        self.active.removeValue(forKey: downloadTask.taskIdentifier)
        self.onFinished?(metadata, staged)
      }
    } catch {
      DispatchQueue.main.async { [weak self] in self?.onError?(metadata, error) }
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let metadata = Self.metadata(task)
    DispatchQueue.main.async { [weak self] in
      self?.active.removeValue(forKey: task.taskIdentifier)
      if let error { self?.onError?(metadata, error) }
    }
  }

  nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                             didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                             totalBytesExpectedToWrite: Int64) {
    guard let metadata = Self.metadata(downloadTask) else { return }
    DispatchQueue.main.async { [weak self] in
      self?.onProgress?(metadata, min(1, Double(totalBytesWritten) / Double(max(1, metadata.size))))
    }
  }

  nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                             willPerformHTTPRedirection response: HTTPURLResponse,
                             newRequest request: URLRequest) async -> URLRequest? {
    nil
  }

  nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async { [weak self] in
      self?.completionHandler?()
      self?.completionHandler = nil
    }
  }
}
