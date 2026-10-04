// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WatchConnectivity

@MainActor
final class ABSWatchBridge: NSObject, WCSessionDelegate {
  private weak var store: SelfHostedStore?
  private var session: WCSession?

  init(store: SelfHostedStore) {
    self.store = store
    super.init()
    guard WCSession.isSupported() else { return }
    session = .default
    session?.delegate = self
    session?.activate()
  }

  func publishPlayer() {
    #if os(iOS)
    guard let store, let session, session.activationState == .activated else { return }
    try? session.updateApplicationContext([
      "absType": "player", "title": store.player.book?.title ?? "",
      "time": store.player.currentTime, "duration": store.player.book?.duration ?? 0,
      "playing": store.player.isPlaying,
    ])
    #endif
  }

  /// Explicit user action. Credentials go only to the paired Watch, never into persistent context.
  func shareConnection() {
    #if os(iOS)
    guard let session, session.isReachable, let connection = store?.connection else {
      store?.errorMessage = SHText("sh_watch_open"); return
    }
    do {
      let data = try JSONEncoder().encode(connection)
      session.sendMessage(["absType": "connection", "connection": data], replyHandler: { [weak self] reply in
        DispatchQueue.main.async {
          self?.store?.errorMessage = reply["ok"] as? Bool == true ? SHText("sh_watch_connected") : SHText("sh_error_signin")
        }
      }, errorHandler: { [weak self] error in
        DispatchQueue.main.async { self?.store?.errorMessage = error.localizedDescription }
      })
    } catch { store?.errorMessage = error.localizedDescription }
    #endif
  }

  func command(_ command: String) {
    #if os(watchOS)
    guard let session, session.isReachable else { store?.errorMessage = SHText("sh_phone_unreachable"); return }
    session.sendMessage(["absType": "command", "command": command], replyHandler: nil) { [weak self] error in
      DispatchQueue.main.async { self?.store?.errorMessage = error.localizedDescription }
    }
    #endif
  }

  nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
    DispatchQueue.main.async { [weak self] in
      self?.store?.phoneReachable = session.isReachable
      self?.consume(session.receivedApplicationContext)
      self?.publishPlayer()
      if let error { self?.store?.errorMessage = error.localizedDescription }
    }
  }

  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    DispatchQueue.main.async { [weak self] in
      self?.store?.phoneReachable = session.isReachable
      self?.publishPlayer()
    }
  }

  nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.consume(applicationContext) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    DispatchQueue.main.async { [weak self] in self?.consume(message) }
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
    DispatchQueue.main.async { [weak self] in
      #if os(watchOS)
      if message["absType"] as? String == "connection", let data = message["connection"] as? Data {
        do {
          let connection = try JSONDecoder().decode(ABSConnection.self, from: data)
          guard let store = self?.store else { replyHandler(["ok": false]); return }
          try store.accept(connection)
          replyHandler(["ok": true])
          Task { await store.refresh() }
        } catch { self?.store?.errorMessage = error.localizedDescription; replyHandler(["ok": false]) }
        return
      }
      #endif
      self?.consume(message)
      replyHandler(["ok": true])
    }
  }

  private func consume(_ message: [String: Any]) {
    guard let store else { return }
    #if os(watchOS)
    if message["absType"] as? String == "player" {
      store.phoneTitle = message["title"] as? String ?? ""
      store.phonePlaying = message["playing"] as? Bool ?? false
      store.phoneTime = message["time"] as? Double ?? 0
      store.phoneDuration = message["duration"] as? Double ?? 0
    }
    #else
    if message["absType"] as? String == "command" {
      switch message["command"] as? String {
      case "toggle": store.player.toggle()
      case "back": store.player.skip(-15)
      case "forward": store.player.skip(30)
      default: return
      }
      publishPlayer()
    }
    #endif
  }

  #if os(iOS)
  nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
  nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
  #endif
}
