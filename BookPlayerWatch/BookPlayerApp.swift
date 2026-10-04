//
//  BookPlayerApp.swift
//  BookPlayerWatch Extension
//
//  Created by gianni.carlo on 18/2/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import SwiftUI
import BookPlayerWatchKit

@main
struct BookPlayerApp: App {
  // swiftlint:disable:next weak_delegate
  @WKApplicationDelegateAdaptor var extensionDelegate: ExtensionDelegate

  @SceneBuilder var body: some Scene {
    WindowGroup {
      if SelfHostedConfiguration.enabled {
        SelfHostedRootView()
      } else {
        NavigationView {
          LoadingView()
        }
      }
    }
  }
}

extension EnvironmentValues {
  @Entry var coreServices: CoreServices?
}
