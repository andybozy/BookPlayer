//
//  CarPlaySceneDelegate.swift
//  BookPlayer
//
//  Created by gianni.carlo on 27/3/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import BookPlayerKit
import CarPlay

@MainActor
class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate {
  lazy var manager = CarPlayManager()
  private weak var selfHostedInterface: CPInterfaceController?

  func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                didConnect interfaceController: CPInterfaceController) {
    if SelfHostedConfiguration.enabled {
      selfHostedInterface = interfaceController
      Task { @MainActor in
        let store = SelfHostedStore.shared
        await store.prepareCarPlay()
        guard self.selfHostedInterface === interfaceController else { return }
        let rows = store.carPlayBooks.prefix(200).map { book in
          let row = CPListItem(text: book.title, detailText: book.author)
          row.handler = { _, completion in
            Task { @MainActor in
              await store.playBook(id: book.id)
              interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
              completion()
            }
          }
          return row
        }
        let template = CPListTemplate(title: NSLocalizedString("sh_libraries", comment: ""), sections: [CPListSection(items: rows)])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
      }
      return
    }
    manager.connect(interfaceController)
  }

  func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
    if SelfHostedConfiguration.enabled { selfHostedInterface = nil; return }
    manager.disconnect()
  }
}
