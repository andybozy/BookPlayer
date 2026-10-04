//
//  AppEnvironment.swift
//  BookPlayer
//
//  Created by BookPlayer on 12/6/25.
//  Copyright © 2025 BookPlayer LLC. All rights reserved.
//

import Foundation

public enum AppEnvironment {
  /// Explicit personal build setting, never enabled against BookPlayer's hosted service.
  public static var isSelfHosted: Bool {
    Bundle.main.object(forInfoDictionaryKey: "BP_SELF_HOSTED") as? String == "YES"
  }

  static func allowsPersonalEndpoint(scheme: String, host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return scheme == "https" && !host.isEmpty && host != "bookplayer.app" && !host.hasSuffix(".bookplayer.app")
  }

  /// Checks if the app is running in a TestFlight environment
  public static var isTestFlight: Bool {
    #if DEBUG
    return false
    #else
    // Check if the app is installed via TestFlight
    guard let receiptURL = Bundle.main.appStoreReceiptURL else {
      return false
    }
    
    return receiptURL.lastPathComponent == "sandboxReceipt"
    #endif
  }
  
  /// Checks if in-app purchases should be enabled
  public static var isPurchaseEnabled: Bool {
    return !isSelfHosted && !isTestFlight
  }
  
  /// Returns the current environment description for debugging
  public static var environmentDescription: String {
    if isTestFlight {
      return "TestFlight"
    }
    #if DEBUG
    return "Debug"
    #else
    return "Production"
    #endif
  }
}

