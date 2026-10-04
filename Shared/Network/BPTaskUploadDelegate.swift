//
//  BPTaskUploadDelegate.swift
//  BookPlayer
//
//  Created by gianni.carlo on 7/3/23.
//  Copyright © 2023 BookPlayer LLC. All rights reserved.
//

import Foundation

class BPTaskUploadDelegate: NSObject, URLSessionTaskDelegate {
  /// Callback triggered when there's an update on the upload progress
  var uploadProgressUpdated: ((URLSessionTask, Double) -> Void)?
  /// Callback triggered when the download task is finished
  var didFinishTask: ((URLSessionTask, Error?) -> Void)?

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didSendBodyData bytesSent: Int64,
    totalBytesSent: Int64,
    totalBytesExpectedToSend: Int64
  ) {
    let uploadProgress = Float(totalBytesSent) / Float(totalBytesExpectedToSend)
    uploadProgressUpdated?(task, Double(uploadProgress))
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if error == nil {
      guard let http = task.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
        didFinishTask?(task, URLError(.badServerResponse))
        return
      }
    }
    didFinishTask?(task, error)
  }
}
