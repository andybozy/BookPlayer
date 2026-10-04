// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Streams authenticated byte ranges through documented resource-loader APIs.
/// No bearer token in URLs and no undocumented AVURLAsset header options.
final class ABSStreamLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate, @unchecked Sendable {
  let asset: AVURLAsset
  private let request: URLRequest
  private let queue = DispatchQueue(label: "BookPlayer.ABS.resource-loader")
  private var session: URLSession!
  // All access is on `queue`, including URLSession's serial delegate queue.
  private var pending: [Int: AVAssetResourceLoadingRequest] = [:]

  init(request: URLRequest) throws {
    guard let url = request.url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw ABSError.invalidResponse
    }
    components.scheme = "abs-audio"
    guard let assetURL = components.url else { throw ABSError.invalidResponse }
    self.request = request
    self.asset = AVURLAsset(url: assetURL)
    super.init()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    let delegateQueue = OperationQueue()
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.underlyingQueue = queue
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    asset.resourceLoader.setDelegate(self, queue: queue)
  }

  func invalidate() { session.invalidateAndCancel() }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                      shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
    var req = request
    if let data = loadingRequest.dataRequest {
      let offset = max(data.requestedOffset, data.currentOffset)
      let end = data.requestedOffset + Int64(data.requestedLength) - 1
      req.setValue(data.requestsAllDataToEndOfResource ? "bytes=\(offset)-" : "bytes=\(offset)-\(max(offset, end))",
                   forHTTPHeaderField: "Range")
    } else {
      req.setValue("bytes=0-1", forHTTPHeaderField: "Range")
    }
    let task = session.dataTask(with: req)
    pending[task.taskIdentifier] = loadingRequest
    task.resume()
    return true
  }

  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
    let ids = pending.filter { $0.value === loadingRequest }.map(\.key)
    for id in ids { pending.removeValue(forKey: id) }
    session.getAllTasks { tasks in
      for task in tasks where ids.contains(task.taskIdentifier) { task.cancel() }
    }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
    guard let loading = pending[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
      http.statusCode == 206,
      let range = http.value(forHTTPHeaderField: "Content-Range"),
      let total = Int64(range.split(separator: "/").last ?? ""), total > 0
    else {
      pending.removeValue(forKey: dataTask.taskIdentifier)?.finishLoading(with: ABSError.invalidResponse)
      completionHandler(.cancel)
      return
    }
    loading.contentInformationRequest?.contentLength = total
    loading.contentInformationRequest?.isByteRangeAccessSupported = true
    loading.contentInformationRequest?.contentType = UTType(mimeType: response.mimeType ?? "audio/mp4")?.identifier
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    pending[dataTask.taskIdentifier]?.dataRequest?.respond(with: data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let loading = pending.removeValue(forKey: task.taskIdentifier) else { return }
    if let error { loading.finishLoading(with: error) } else { loading.finishLoading() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}
