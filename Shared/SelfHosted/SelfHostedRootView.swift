// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
#if os(watchOS)
import WatchKit
#else
import UIKit
#endif

@MainActor
public struct SelfHostedRootView: View {
  @ObservedObject private var store: SelfHostedStore
  @Environment(\.scenePhase) private var scenePhase
  @State private var showSignIn = false

  public init(store: SelfHostedStore = .shared) { self.store = store }

  public var body: some View {
    NavigationStack {
      Group {
        if store.connection == nil {
          ABSSignInView(store: store)
        } else {
          List {
            if store.player.book != nil {
              NavigationLink { ABSPlayerView(store: store) } label: {
                Label(store.player.book?.title ?? SHText("sh_player"), systemImage: "waveform")
              }
            }
            #if os(watchOS)
            Section(SHText("sh_on_iphone")) {
              Text(store.phoneTitle.isEmpty ? SHText("sh_nothing_playing") : store.phoneTitle)
              HStack {
                Button { store.phoneCommand("back") } label: { Image(systemName: "gobackward.15") }
                  .accessibilityLabel(SHText("sh_back"))
                Button { store.phoneCommand("toggle") } label: { Image(systemName: store.phonePlaying ? "pause.fill" : "play.fill") }
                  .accessibilityLabel(SHText("sh_play_pause"))
                Button { store.phoneCommand("forward") } label: { Image(systemName: "goforward.30") }
                  .accessibilityLabel(SHText("sh_forward"))
              }
              .buttonStyle(.borderless)
              .disabled(!store.phoneReachable)
              if !store.phoneReachable { Text(SHText("sh_phone_unreachable")).font(.caption) }
            }
            #endif
            Section(SHText("sh_libraries")) {
              ForEach(store.state.libraries) { library in
                NavigationLink(library.name) { ABSLibraryView(store: store, library: library) }
              }
              if store.state.libraries.isEmpty { Text(SHText("sh_empty_libraries")) }
            }
            Section(SHText("sh_on_device")) {
              NavigationLink(SHText("sh_downloads")) { ABSOfflineView(store: store) }
              Text(String(format: SHText("sh_pending_count"), store.state.pending.count)).font(.caption)
              Button(SHText("sh_sync")) { Task { await store.refresh() } }
            }
            if !store.conflicts.isEmpty {
              Section(SHText("sh_conflicts")) {
                Text(SHText("sh_conflict_explanation")).font(.caption)
                ForEach(store.conflicts.keys.sorted(), id: \.self) { id in
                  let title = store.state.offline[id]?.book.title ?? store.state.books.values.flatMap { $0 }.first { $0.id == id }?.title ?? id
                  VStack(alignment: .leading, spacing: 8) {
                    Text(title).font(.headline)
                    Text(SHText("sh_device_position") + " " + ABSClock(store.state.pending[id]?.currentTime ?? 0))
                    Text(SHText("sh_server_position") + " " + ABSClock((store.conflicts[id] ?? nil)?.currentTime ?? 0))
                    Button(SHText("sh_use_server")) { Task { await store.resolve(bookID: id, useLocal: false) } }
                    Button(SHText("sh_use_device")) { Task { await store.resolve(bookID: id, useLocal: true) } }
                  }
                  .buttonStyle(.borderless)
                }
              }
            }
            Section(SHText("sh_account")) {
              Text(store.connection?.username ?? "")
              Text(store.connection?.server.host ?? "").font(.caption)
              #if os(iOS)
              Button(SHText("sh_watch_connect")) { store.shareWithWatch() }
              #endif
              Button(SHText("sh_signin_again")) { showSignIn = true }
              Button(SHText("sh_signout"), role: .destructive) { store.signOut() }
                .disabled(!store.canSignOut)
              if !store.canSignOut { Text(SHText("sh_pending_signout")).font(.caption) }
            }
          }
          .navigationTitle(SHText("sh_libraries"))
          .refreshable { await store.refresh() }
        }
      }
      .task { store.start() }
      .onChange(of: scenePhase) { _, phase in
        if phase == .active { Task { await store.refresh() } }
        else { Task { await store.flush() } }
      }
      .sheet(isPresented: $showSignIn) { NavigationStack { ABSSignInView(store: store) } }
      .alert(SHText("sh_message"), isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
        Button(SHText("sh_ok")) { store.errorMessage = nil }
      } message: { Text(store.errorMessage ?? "") }
    }
  }
}

@MainActor
private struct ABSSignInView: View {
  @ObservedObject var store: SelfHostedStore
  @Environment(\.dismiss) private var dismiss
  @State private var server = SelfHostedConfiguration.defaultServer
  @State private var username = ""
  @State private var password = ""

  var body: some View {
    Form {
      Section(SHText("sh_signin")) {
        TextField(SHText("sh_server"), text: $server)
          .autocorrectionDisabled()
        TextField(SHText("sh_username"), text: $username)
          .autocorrectionDisabled()
        SecureField(SHText("sh_password"), text: $password)
        Button(SHText("sh_signin")) {
          Task {
            await store.signIn(server: server, username: username, password: password)
            password = ""
            if store.errorMessage == nil, store.connection != nil { dismiss() }
          }
        }.disabled(store.busy || username.isEmpty || password.isEmpty)
        if store.busy { ProgressView() }
      }
      Text(SHText("sh_signin_help")).font(.caption)
      #if os(watchOS)
      Text(SHText("sh_watch_pair_help")).font(.caption)
      #endif
    }
    .navigationTitle(SHText("sh_signin"))
    .onAppear {
      if let connection = store.connection { server = connection.server.absoluteString; username = connection.username }
    }
  }
}

@MainActor
private struct ABSLibraryView: View {
  @ObservedObject var store: SelfHostedStore
  let library: ABSLibrary
  @State private var search = ""
  private var books: [ABSBook] {
    (store.state.books[library.id] ?? []).filter { search.isEmpty || $0.searchableText.localizedCaseInsensitiveContains(search) }
      .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }
  var body: some View {
    List {
      ForEach(books) { book in
        NavigationLink { ABSBookView(store: store, book: book) } label: { ABSBookRow(store: store, book: book) }
      }
      if books.isEmpty { Text(SHText("sh_empty_books")) }
    }
    .navigationTitle(library.name)
    .searchable(text: $search, prompt: Text(SHText("sh_search")))
    .task { await store.refresh(libraryID: library.id) }
    .refreshable { await store.refresh(libraryID: library.id) }
  }
}

@MainActor
private struct ABSOfflineView: View {
  @ObservedObject var store: SelfHostedStore
  var body: some View {
    List {
      ForEach(store.state.offline.values.map(\.book).sorted { $0.title < $1.title }) { book in
        NavigationLink { ABSBookView(store: store, book: book) } label: { ABSBookRow(store: store, book: book) }
      }
      if store.state.offline.isEmpty { Text(SHText("sh_offline_help")) }
    }.navigationTitle(SHText("sh_downloads"))
  }
}

@MainActor
private struct ABSBookRow: View {
  @ObservedObject var store: SelfHostedStore
  let book: ABSBook
  var body: some View {
    HStack {
      ABSCoverView(store: store, id: book.id).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
      VStack(alignment: .leading) {
        Text(book.title).lineLimit(2)
        Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        if store.isOffline(book.id) { Label(SHText("sh_downloaded"), systemImage: "checkmark.circle").font(.caption2) }
        else if let progress = store.downloads[book.id] { ProgressView(value: progress) }
        else if store.state.offline[book.id] != nil { Text(SHText("sh_incomplete")).font(.caption2) }
      }
    }
  }
}

@MainActor
private struct ABSBookView: View {
  @ObservedObject var store: SelfHostedStore
  @State var book: ABSBook
  @State private var confirmRemoval = false
  var body: some View {
    List {
      ABSCoverView(store: store, id: book.id).frame(height: 140)
      Text(book.title).font(.headline)
      Text(book.author)
      if let narrator = book.media.metadata.narratorName, !narrator.isEmpty { Text(SHText("sh_narrator") + " " + narrator).font(.caption) }
      if let series = book.media.metadata.seriesName, !series.isEmpty { Text(series).font(.caption) }
      Text(ABSClock(book.duration)).font(.caption)
      if let language = book.media.metadata.language { Text(language).font(.caption) }
      if book.media.metadata.abridged == true { Text(SHText("sh_abridged")).font(.caption) }
      Button(SHText("sh_play")) { Task { await store.play(book) } }
      if store.player.book?.id == book.id {
        NavigationLink(SHText("sh_player")) { ABSPlayerView(store: store) }
      }
      if !store.isOffline(book.id) {
        Button(SHText("sh_download")) { Task { await store.download(book) } }
        Text(SHText("sh_wifi_download")).font(.caption)
      }
      if let progress = store.downloads[book.id] { ProgressView(value: progress) }
      if store.state.offline[book.id] != nil {
        Button(SHText("sh_remove_download"), role: .destructive) { confirmRemoval = true }
          .disabled(store.player.book?.id == book.id && store.player.isPlaying)
      }
      if let description = book.media.metadata.descriptionPlain, !description.isEmpty { Text(description).font(.caption) }
      if !book.chapters.isEmpty {
        Section(SHText("sh_chapters")) {
          ForEach(book.chapters) { chapter in
            Button {
              Task {
                if store.player.book?.id != book.id { await store.play(book) }
                if store.player.book?.id == book.id { store.player.seek(chapter.start) }
              }
            } label: { VStack(alignment: .leading) { Text(chapter.title); Text(ABSClock(chapter.start)).font(.caption) } }
          }
        }
      }
    }
    .navigationTitle(book.title)
    .task { book = await store.details(book) }
    .confirmationDialog(SHText("sh_remove_download"), isPresented: $confirmRemoval) {
      Button(SHText("sh_remove_download"), role: .destructive) { Task { await store.removeDownload(book.id) } }
    } message: { Text(SHText("sh_remove_help")) }
  }
}

@MainActor
private struct ABSPlayerView: View {
  @ObservedObject var store: SelfHostedStore
  @State private var position: Double = 0
  @State private var dragging = false
  var body: some View {
    List {
      if let book = store.player.book {
        Text(book.title).font(.headline)
        Text(book.author).font(.caption)
        if let chapter = book.chapters.last(where: { $0.start <= store.player.currentTime }) { Text(chapter.title).font(.caption) }
        Slider(value: $position, in: 0...max(1, book.duration)) { editing in
          dragging = editing
          if !editing { store.player.seek(position) }
        }.accessibilityLabel(SHText("sh_position"))
        Text(ABSClock(store.player.currentTime) + " / " + ABSClock(book.duration)).font(.caption).monospacedDigit()
        HStack {
          Button { store.player.skip(-15) } label: { Image(systemName: "gobackward.15") }
            .accessibilityLabel(SHText("sh_back"))
          Spacer()
          Button { store.player.toggle() } label: { Image(systemName: store.player.isPlaying ? "pause.fill" : "play.fill") }
            .accessibilityLabel(SHText("sh_play_pause"))
          Spacer()
          Button { store.player.skip(30) } label: { Image(systemName: "goforward.30") }
            .accessibilityLabel(SHText("sh_forward"))
        }.buttonStyle(.borderless)
        Picker(SHText("sh_speed"), selection: Binding(get: { store.player.rate }, set: { store.player.setRate($0) })) {
          ForEach([Float(0.75), 1, 1.25, 1.5, 1.75, 2, 2.5, 3], id: \.self) { value in Text(String(format: "%.2g×", value)).tag(value) }
        }
        Menu(SHText("sh_sleep")) {
          ForEach([5, 15, 30, 45, 60], id: \.self) { minutes in
            Button("\(minutes) min") { store.player.sleep(after: minutes) }
          }
          Button(SHText("sh_sleep_off")) { store.player.sleep(after: nil) }
        }
        if let deadline = store.player.sleepDeadline { Text(deadline, style: .timer) }
      }
    }
    .navigationTitle(SHText("sh_player"))
    .onAppear { position = store.player.currentTime }
    .onChange(of: store.player.currentTime) { _, time in if !dragging { position = time } }
  }
}

@MainActor
private struct ABSCoverView: View {
  let store: SelfHostedStore
  let id: String
  @State private var data: Data?
  var body: some View {
    Group {
      if let data, let image = UIImage(data: data) {
        Image(uiImage: image).resizable().scaledToFit()
      } else { Image(systemName: "book.closed").resizable().scaledToFit().foregroundStyle(.secondary).padding(6) }
    }
    .accessibilityHidden(true)
    .task(id: id) { data = await store.cover(id) }
  }
}

private func ABSClock(_ seconds: Double) -> String {
  guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
  let value = Int(seconds)
  return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
