// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Only this origin receives the ABS bearer credential. Redirects are not followed.
final class ABSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? {
    nil
  }
}

final class ABSClient: @unchecked Sendable {
  let connection: ABSConnection
  private let session: URLSession
  private let redirectPolicy = ABSRedirectPolicy()

  init(connection: ABSConnection) {
    self.connection = connection
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 30
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    self.session = URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
  }

  deinit { session.invalidateAndCancel() }

  func request(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
    var request = URLRequest(url: try connection.resourceURL(path))
    request.httpMethod = method
    request.httpBody = body
    request.setValue("BookPlayerSelfHosted/1.0", forHTTPHeaderField: "User-Agent")
    request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    return request
  }

  private func send(_ request: URLRequest) async throws -> Data {
    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw ABSError.invalidResponse }
    guard (200...299).contains(http.statusCode) else { throw ABSError.http(http.statusCode) }
    return data
  }

  static func signIn(server: URL, username: String, password: String) async throws -> ABSConnection {
    let temporary = ABSConnection(server: server, userID: "", username: username, token: "")
    let client = ABSClient(connection: temporary)
    var request = try client.request("/login", method: "POST",
      body: JSONSerialization.data(withJSONObject: ["username": username, "password": password]))
    request.setValue(nil, forHTTPHeaderField: "Authorization")
    struct Login: Decodable {
      struct User: Decodable { let id: String; let token: String }
      let user: User
    }
    let response = try JSONDecoder().decode(Login.self, from: await client.send(request))
    guard !response.user.token.isEmpty else { throw ABSError.invalidResponse }
    return ABSConnection(server: server, userID: response.user.id, username: username, token: response.user.token)
  }

  func libraries() async throws -> [ABSLibrary] {
    struct Response: Decodable { let libraries: [ABSLibrary] }
    return try JSONDecoder().decode(Response.self, from: await send(request("/api/libraries"))).libraries
      .filter { $0.mediaType == "book" }
  }

  func books(libraryID: String) async throws -> [ABSBook] {
    struct Page: Decodable { let results: [ABSBook]; let total: Int }
    var result: [ABSBook] = []
    var page = 0
    repeat {
      try Task.checkCancellation()
      // Query parameters here are local constants; resource URLs from the server never carry secrets.
      var url = URLComponents(url: try connection.resourceURL("/api/libraries/\(component(libraryID))/items"), resolvingAgainstBaseURL: false)
      url?.queryItems = [URLQueryItem(name: "limit", value: "200"), URLQueryItem(name: "page", value: "\(page)")]
      var req = try request("/api/libraries/\(component(libraryID))/items")
      req.url = url?.url
      guard req.url != nil else { throw ABSError.invalidResponse }
      let response = try JSONDecoder().decode(Page.self, from: await send(req))
      result.append(contentsOf: response.results)
      if response.results.isEmpty || result.count >= response.total { break }
      page += 1
    } while true
    var seen: Set<String> = []
    return result.filter { seen.insert($0.id).inserted }
  }

  func book(_ id: String) async throws -> ABSBook {
    var req = try request("/api/items/\(component(id))")
    guard let url = req.url else { throw ABSError.invalidResponse }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "expanded", value: "1")]
    req.url = components?.url
    let book = try JSONDecoder().decode(ABSBook.self, from: await send(req))
    try book.validateAudio()
    return book
  }

  func progress(_ id: String) async throws -> ABSProgress? {
    do {
      let data = try await send(request("/api/me/progress/\(component(id))"))
      if data == Data("null".utf8) { return nil }
      return try JSONDecoder().decode(ABSProgress.self, from: data)
    } catch ABSError.http(404) { return nil }
  }

  func update(_ checkpoint: ABSCheckpoint) async throws {
    guard checkpoint.duration.isFinite, checkpoint.duration > 0, checkpoint.currentTime.isFinite else {
      throw ABSError.invalidResponse
    }
    let body = try JSONSerialization.data(withJSONObject: [
      "currentTime": checkpoint.currentTime, "duration": checkpoint.duration,
      "progress": min(1, max(0, checkpoint.currentTime / checkpoint.duration)),
      "isFinished": checkpoint.isFinished,
    ])
    _ = try await send(request("/api/me/progress/\(component(checkpoint.bookID))", method: "PATCH", body: body))
  }

  func cover(_ id: String) async throws -> Data {
    var req = try request("/api/items/\(component(id))/cover")
    guard let url = req.url else { throw ABSError.invalidResponse }
    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "width", value: "320"),
                             URLQueryItem(name: "height", value: "320"),
                             URLQueryItem(name: "format", value: "jpeg")]
    req.url = components?.url
    return try await send(req)
  }

  private func component(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
  }
}
