// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import BookPlayerKit

final class SelfHostedABSTests: XCTestCase {
  private let origin = URL(string: "https://books.example.test")!

  func testServerRequiresAnHTTPSOriginWithoutEmbeddedCredentials() throws {
    XCTAssertEqual(try ABSConnection.validatedServer("https://books.example.test"), origin)
    for invalid in ["http://books.example.test", "https://user:password@books.example.test",
      "https://books.example.test?token=x", "https://books.example.test/#x", "https://books.example.test/abs"] {
      XCTAssertThrowsError(try ABSConnection.validatedServer(invalid))
    }
  }

  func testServerSuppliedResourceCannotExfiltrateTheBearerToken() throws {
    let connection = ABSConnection(server: origin, userID: "u", username: "test", token: "secret")
    XCTAssertEqual(try connection.resourceURL("/api/items/book/file/1").host, origin.host)
    for invalid in ["https://evil.test/audio", "//evil.test/audio", "http://books.example.test/audio",
      "https://books.example.test:444/audio", "/audio?token=secret", "https://user@books.example.test/audio"] {
      XCTAssertThrowsError(try connection.resourceURL(invalid))
    }
  }

  func testAnIntentionalRewindIsUploadedWhenServerRevisionHasNotChanged() {
    let checkpoint = ABSCheckpoint(bookID: "b", currentTime: 30, duration: 500, isFinished: false, baseRevision: 100)
    let remote = ABSProgress(currentTime: 300, duration: 500, isFinished: false, lastUpdate: 100)
    XCTAssertEqual(checkpoint.decision(remote: remote), .upload)
  }

  func testOfflineConflictRequiresAnExplicitChoiceEvenIfLocalPositionIsFurtherAhead() {
    let checkpoint = ABSCheckpoint(bookID: "b", currentTime: 400, duration: 500, isFinished: false, baseRevision: 100)
    let remote = ABSProgress(currentTime: 40, duration: 500, isFinished: false, lastUpdate: 101)
    XCTAssertEqual(checkpoint.decision(remote: remote), .conflict)
  }

  func testRetryAfterLostAcknowledgementDoesNotCreateAFakeConflict() {
    let checkpoint = ABSCheckpoint(bookID: "b", currentTime: 40, duration: 500, isFinished: false, baseRevision: 100)
    let remote = ABSProgress(currentTime: 40, duration: 500, isFinished: false, lastUpdate: 101)
    XCTAssertEqual(checkpoint.decision(remote: remote), .acknowledge)
  }

  func testCompletionAndDeletedServerProgressAreNotSilentlyOverwritten() {
    let checkpoint = ABSCheckpoint(bookID: "b", currentTime: 500, duration: 500, isFinished: true, baseRevision: 100)
    XCTAssertEqual(checkpoint.decision(remote: nil), .conflict)
    XCTAssertEqual(checkpoint.decision(remote: ABSProgress(currentTime: 500, duration: 500, isFinished: false, lastUpdate: 101)), .conflict)
    let fresh = ABSCheckpoint(bookID: "new", currentTime: 1, duration: 500, isFinished: false, baseRevision: 0)
    XCTAssertEqual(fresh.decision(remote: nil), .upload)
  }

  func testMultiPartTracksAreOrderedByGlobalOffsetAndChapterTimesRemainGlobal() throws {
    // Shape taken from the deployed ABS 2.37.1 expanded-item endpoint.
    let json = #"""
    {"id":"b","libraryId":"l","media":{"metadata":{"title":"Multipart","authorName":"Author"},
      "duration":20,"tracks":[
        {"index":2,"startOffset":10,"duration":10,"contentUrl":"/api/items/b/file/2","metadata":{"filename":"02.mp3","size":100}},
        {"index":1,"startOffset":0,"duration":10,"contentUrl":"/api/items/b/file/1","metadata":{"filename":"01.mp3","size":100}}
      ],"chapters":[{"id":0,"start":0,"end":10,"title":"One"},{"id":1,"start":10,"end":20,"title":"Two"}]}}
    """#
    let book = try JSONDecoder().decode(ABSBook.self, from: Data(json.utf8))
    try book.validateAudio()
    XCTAssertEqual(book.tracks.map(\.index), [1, 2])
    XCTAssertEqual(book.chapters[1].start, 10)
  }

  func testRedirectPolicyRejectsRedirects() async {
    let policy = ABSRedirectPolicy()
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: origin)
    let response = HTTPURLResponse(url: origin, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.test"])!
    let redirected = await policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: URL(string: "https://evil.test")!))
    XCTAssertNil(redirected)
    session.invalidateAndCancel()
  }
}
