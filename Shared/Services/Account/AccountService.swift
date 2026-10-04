//
//  AccountService.swift
//  BookPlayer
//
//  Created by gianni.carlo on 10/4/22.
//  Copyright © 2022 BookPlayer LLC. All rights reserved.
//

import CoreData
import Foundation
import RevenueCat

public enum AccountError: Error {
  /// RevenueCat can't find the products
  case emptyProducts
  /// RevenueCat didn't find an active subscription
  case inactiveSubscription
  /// iOS apps running on MacOS can't show subscription management
  case managementUnavailable
  /// Sign in with Apple didn't return identityToken
  case missingToken
  /// In-app purchases are disabled in TestFlight builds
  case testFlightPurchasesDisabled
}

public enum SecondOnboardingError: Error {
  case notApplicable
}

public enum AccessLevel: String, CaseIterable, Identifiable {
  case free, plus, pro, selfHosted

  public var id: String { rawValue }
}

extension AccountError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .emptyProducts:
      return "Empty products!"
    case .managementUnavailable:
      return
        "Subscription Management is not available for iOS apps running on Macs, please go to the App Store app to manage your existing subscriptions."
    case .missingToken:
      return "Identity token not available. Please sign in again."
    case .inactiveSubscription:
      return
        "We couldn't find an active subscription for your account. If you believe this is an error, please contact us at support@bookplayer.app"
    case .testFlightPurchasesDisabled:
      return "In-app purchases are disabled in TestFlight builds. Please download the app from the App Store for donations or new subscriptions."
    }
  }
}

public protocol AccountServiceProtocol {
  func getAccountId() -> String?
  func getAnonymousId() -> String?
  func getAccount() -> Account?
  func hasAccount() -> Bool
  func hasSyncEnabled() -> Bool
  func hasPlusAccess() -> Bool

  @discardableResult
  func createAccount(donationMade: Bool) -> Account

  func updateAccount(from customerInfo: CustomerInfo)

  func updateAccount(
    id: String?,
    email: String?,
    donationMade: Bool?,
    hasSubscription: Bool?
  )

  func getHardcodedSubscriptionOptions() -> [PricingModel]
  func getSubscriptionOptions() async throws -> [PricingModel]

  func subscribe(option: PricingModel) async throws -> Bool
  func restorePurchases() async throws -> CustomerInfo

  func loginTestAccount(token: String) async throws
  func login(
    with token: String,
    userId: String
  ) async throws -> Account?
  /// Load up stored user into RevenueCat's SDK to start listening to events
  /// - Parameter delegate: Delegate that will handle any changes to the customer info
  func loginIfUserExists(delegate: PurchasesDelegate)

  func logout() throws
  func deleteAccount() async throws -> String

  func handlePasskeyLogin(response: PasskeyLoginResponse) async throws

  /// Handle credentials transferred from iPhone to Watch
  @MainActor
  func loginWithTransferredCredentials(
    token: String,
    accountId: String,
    email: String,
    hasSubscription: Bool,
    donationMade: Bool
  ) async throws -> Account?

  func getSecondOnboarding<T: Decodable>() async throws -> T
}

@Observable
public final class AccountService: AccountServiceProtocol {
  let monthlySubscriptionId = "com.tortugapower.audiobookplayer.subscription.pro"
  let yearlySubscriptionId = "com.tortugapower.audiobookplayer.subscription.pro.yearly"
  var dataManager: DataManager!
  var client: NetworkClientProtocol!
  var keychain: KeychainServiceProtocol!
  public var account: SimpleAccount!
  private var provider: NetworkProvider<AccountAPI>!

  public var accessLevel: AccessLevel!

  public init() {}

  public func setup(
    dataManager: DataManager,
    client: NetworkClientProtocol = NetworkClient(),
    keychain: KeychainServiceProtocol = KeychainService()
  ) {
    self.dataManager = dataManager
    self.client = client
    self.keychain = keychain
    self.provider = NetworkProvider(client: client)
    self.accessLevel = getAccessLevel()

    let storedAccount: Account = getAccount() ?? createAccount(
      donationMade: UserDefaults.standard.bool(forKey: Constants.UserDefaults.donationMade)
    )

    self.account = SimpleAccount(account: storedAccount)
  }

  public func setDelegate(_ delegate: PurchasesDelegate) {
    guard !AppEnvironment.isSelfHosted else { return }
    Purchases.shared.delegate = delegate
  }

  public func getAccountId() -> String? {
    if let account = self.getAccount(),
      !account.id.isEmpty
    {
      return account.id
    } else {
      return nil
    }
  }

  public func getAnonymousId() -> String? {
    if AppEnvironment.isSelfHosted { return nil }
    return Purchases.shared.cachedCustomerInfo?.id
  }

  public func getAccount() -> Account? {
    let context = self.dataManager.getContext()
    let fetch: NSFetchRequest<Account> = Account.fetchRequest()
    fetch.returnsObjectsAsFaults = false

    return (try? context.fetch(fetch).first)
  }

  public func hasAccount() -> Bool {
    let context = self.dataManager.getContext()

    if let count = try? context.count(for: Account.fetchRequest()),
      count > 0
    {
      return true
    }

    return false
  }

  public func hasSyncEnabled() -> Bool {
    if AppEnvironment.isSelfHosted {
      let session: SelfHostedSession? = try? keychain.get(.selfHostedAccount)
      let token: String? = try? keychain.get(.token)
      return session?.selfHosted == true && session?.accountId == getAccountId()
        && session?.server == Bundle.main.configurationString(for: .apiDomain) && token != nil
    }
    return Purchases.shared.cachedCustomerInfo?.entitlements.all["pro"]?.isActive == true
  }

  public func hasPlusAccess() -> Bool {
    if AppEnvironment.isSelfHosted { return hasSyncEnabled() }
    guard let cachedInfo = Purchases.shared.cachedCustomerInfo else {
      return getAccount()?.donationMade == true
    }

    let entitlements = cachedInfo.entitlements.all

    if entitlements["plus"]?.isActive == true
      || entitlements["pro"]?.isActive == true
    {
      return true
    }

    if entitlements["pro"]?.isActive == false,
      let subscriptionInfo = getSubscriptionInfo(from: cachedInfo),
      subscriptionInfo.refundedAt != nil
    {
      return false
    }

    return getAccount()?.donationMade == true
  }

  private func getAccessLevel() -> AccessLevel {
    if hasSyncEnabled() {
      return AppEnvironment.isSelfHosted ? .selfHosted : .pro
    } else if hasPlusAccess() {
      return .plus
    } else {
      return .free
    }
  }

  private func getSubscriptionInfo(from customerInfo: CustomerInfo) -> SubscriptionInfo? {
    var currentSubscription: SubscriptionInfo?

    for option in PricingOption.allCases {
      if let subscription = customerInfo.subscriptionsByProductIdentifier[option.rawValue] {
        currentSubscription = subscription
        break
      }
    }

    return currentSubscription
  }

  @discardableResult
  public func createAccount(donationMade: Bool) -> Account {
    let context = self.dataManager.getContext()
    let account = Account.create(in: context)
    account.id = ""
    account.email = ""
    account.hasSubscription = false
    account.donationMade = donationMade
    self.dataManager.saveContext()

    return account
  }

  public func updateAccount(from customerInfo: CustomerInfo) {
    guard !AppEnvironment.isSelfHosted else { return }
    self.updateAccount(
      hasSubscription: !customerInfo.activeSubscriptions.isEmpty
    )
  }

  public func updateAccount(
    id: String? = nil,
    email: String? = nil,
    donationMade: Bool? = nil,
    hasSubscription: Bool? = nil
  ) {
    guard let account = self.getAccount() else { return }

    if let id = id {
      account.id = id
    }

    if let email = email {
      account.email = email
    }

    if let donationMade = donationMade {
      account.donationMade = donationMade
    }

    if let hasSubscription = hasSubscription {
      account.hasSubscription = hasSubscription
    }

    self.dataManager.saveContext()

    DispatchQueue.main.async {
      self.accessLevel = self.getAccessLevel()
      self.account = .init(account: account)
      NotificationCenter.default.post(name: .accountUpdate, object: self)
    }
  }

  public func getHardcodedSubscriptionOptions() -> [PricingModel] {
    return [
      PricingModel(
        id: yearlySubscriptionId,
        title: "49.99 USD \("yearly_title".localized)",
        price: 49.99
      ),
      PricingModel(
        id: monthlySubscriptionId,
        title: "4.99 USD \("monthly_title".localized)",
        price: 4.99
      ),
    ]
  }

  public func getSubscriptionOptions() async throws -> [PricingModel] {
    if AppEnvironment.isSelfHosted { return [] }
    let products = await Purchases.shared.products([yearlySubscriptionId, monthlySubscriptionId])

    var options = [PricingModel]()

    if let product = products.first(where: { $0.productIdentifier == yearlySubscriptionId }) {
      options.append(
        PricingModel(
          id: product.productIdentifier,
          title: "\(product.localizedPriceString) \("yearly_title".localized)",
          price: product.priceDecimalNumber.doubleValue
        )
      )
    }

    if let product = products.first(where: { $0.productIdentifier == monthlySubscriptionId }) {
      options.append(
        PricingModel(
          id: product.productIdentifier,
          title: "\(product.localizedPriceString) \("monthly_title".localized)",
          price: product.priceDecimalNumber.doubleValue
        )
      )
    }

    if options.isEmpty {
      throw AccountError.emptyProducts
    }

    return options
  }

  public func subscribe(option: PricingModel) async throws -> Bool {
    return try await subscribe(productId: option.id)
  }

  private func subscribe(productId: String) async throws -> Bool {
    guard AppEnvironment.isPurchaseEnabled else {
      throw AccountError.testFlightPurchasesDisabled
    }
    
    let products = await Purchases.shared.products([productId])

    guard let product = products.first else {
      throw AccountError.emptyProducts
    }

    let result = try await Purchases.shared.purchase(product: product)

    if !result.userCancelled {
      self.updateAccount(donationMade: true, hasSubscription: true)
    }

    return result.userCancelled
  }

  public func restorePurchases() async throws -> CustomerInfo {
    guard AppEnvironment.isPurchaseEnabled else {
      throw AccountError.testFlightPurchasesDisabled
    }
    
    return try await Purchases.shared.restorePurchases()
  }

  public func loginTestAccount(token: String) async throws {
    guard !AppEnvironment.isSelfHosted else { throw AccountError.missingToken }
    let userId = "001918.a2d23624056d45618b7c2699d98c535e.2333"
    self.updateAccount(
      id: userId,
      email: "gcarlo89@hotmail.com",
      donationMade: true,
      hasSubscription: true
    )

    try self.keychain.set(token, key: .token)

    _ = try await Purchases.shared.logIn(userId)
    UserDefaults.sharedDefaults.set(userId, forKey: "rcUserId")
  }

  public func login(
    with token: String,
    userId: String
  ) async throws -> Account? {
    guard !AppEnvironment.isSelfHosted else { throw AccountError.missingToken }
    let response: LoginResponse = try await provider.request(.login(token: token))

    try self.keychain.set(response.token, key: .token)

    // Identify to RevenueCat with the server's canonical id (the account's
    // external_id) as the single source of truth, so a user signing in with
    // Apple lands on the same RevenueCat user as their other credentials.
    // Fall back to the Apple credential id only if an older response omits it.
    let rcUserId = response.revenuecatId ?? userId
    let (customerInfo, _) = try await Purchases.shared.logIn(rcUserId)
    UserDefaults.sharedDefaults.set(rcUserId, forKey: "rcUserId")

    if let existingAccount = self.getAccount() {
      // Preserve donation made flag from stored account
      let donationMade = existingAccount.donationMade || !customerInfo.nonSubscriptions.isEmpty

      self.updateAccount(
        id: rcUserId,
        email: response.email,
        donationMade: donationMade,
        hasSubscription: !customerInfo.activeSubscriptions.isEmpty
      )
    }

    return self.getAccount()
  }

  public func handlePasskeyLogin(response: PasskeyLoginResponse) async throws {
    guard !AppEnvironment.isSelfHosted else { throw AccountError.missingToken }
    // Store the token
    try self.keychain.set(response.token, key: .token)

    // Use revenuecat_id for RevenueCat (Apple ID if exists, otherwise public_id)
    let userId = response.revenuecatId
    let (customerInfo, _) = try await Purchases.shared.logIn(userId)
    UserDefaults.sharedDefaults.set(userId, forKey: "rcUserId")

    // Update local account with subscription status from server
    let existingDonationMade = self.getAccount()?.donationMade ?? false
    self.updateAccount(
      id: userId,
      email: response.email,
      donationMade: existingDonationMade || !customerInfo.nonSubscriptions.isEmpty,
      hasSubscription: !customerInfo.activeSubscriptions.isEmpty
    )
  }

  @MainActor
  public func loginWithTransferredCredentials(
    token: String,
    accountId: String,
    email: String,
    hasSubscription: Bool,
    donationMade: Bool
  ) async throws -> Account? {
    // Store the token
    try self.keychain.set(token, key: .token)
    if AppEnvironment.isSelfHosted {
      try await refreshSelfHostedSession()
      return getAccount()
    }
    // Log in to RevenueCat
    let (customerInfo, _) = try await Purchases.shared.logIn(accountId)
    UserDefaults.sharedDefaults.set(accountId, forKey: "rcUserId")

    // Update local account
    self.updateAccount(
      id: accountId,
      email: email,
      donationMade: donationMade || !customerInfo.nonSubscriptions.isEmpty,
      hasSubscription: hasSubscription || !customerInfo.activeSubscriptions.isEmpty
    )

    return self.getAccount()
  }

  public func loginIfUserExists(delegate: PurchasesDelegate) {
    if AppEnvironment.isSelfHosted {
      Task { @MainActor [weak self] in try? await self?.refreshSelfHostedSession() }
      return
    }
    guard let account = self.getAccount(), !account.id.isEmpty else {
      Purchases.shared.delegate = delegate
      return
    }

    Purchases.shared.logIn(account.id) { [weak self] customerInfo, _, _ in
      defer {
        Purchases.shared.delegate = delegate
      }

      guard let customerInfo = customerInfo else { return }

      self?.updateAccount(from: customerInfo)
    }
  }

  public func logout() throws {
    try self.keychain.remove(.token)

    self.updateAccount(
      id: "",
      email: "",
      hasSubscription: false
    )

    if AppEnvironment.isSelfHosted {
      try keychain.remove(.selfHostedAccount)
    } else {
      Purchases.shared.logOut { _, _ in }
    }
    UserDefaults.sharedDefaults.removeObject(forKey: "rcUserId")

    NotificationCenter.default.post(name: .logout, object: self)
  }

  public func deleteAccount() async throws -> String {
    let response: DeleteResponse = try await provider.request(.delete)

    try logout()

    return response.message
  }

  public func getSecondOnboarding<T: Decodable>() async throws -> T {
    guard !AppEnvironment.isSelfHosted else { throw SecondOnboardingError.notApplicable }
    guard
      let customerInfo = Purchases.shared.cachedCustomerInfo,
      let countryCode = await Storefront.currentStorefront?.countryCode
    else {
      throw SecondOnboardingError.notApplicable
    }

    let entitlements = customerInfo.entitlements.all

    if entitlements["plus"]?.isActive == true
      || entitlements["pro"]?.isActive == true
    {
      throw SecondOnboardingError.notApplicable
    }

    /// Verify that it wasn't refunded
    if entitlements["pro"]?.isActive == false,
      let subscriptionInfo = getSubscriptionInfo(from: customerInfo),
      subscriptionInfo.refundedAt == nil
    {
      throw SecondOnboardingError.notApplicable
    }

    return try await provider.request(
      .secondOnboarding(
        anonymousId: customerInfo.id,
        firstSeen: customerInfo.firstSeen.timeIntervalSince1970,
        region: countryCode,
        version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
      )
    )
  }
}

/// Separate capability from a paid subscription. Accepted only from the configured personal backend.
public struct SelfHostedSession: Codable {
  public let token: String
  public let accountId: String
  public let email: String
  public let selfHosted: Bool
  public let server: String?
}

extension AccountService {
  @MainActor
  public func loginSelfHosted(username: String, password: String) async throws {
    guard AppEnvironment.isSelfHosted else { throw AccountError.missingToken }
    let response: SelfHostedSession = try await client.request(
      path: "/v1/user/login", method: .post,
      parameters: ["username": username, "password": password]
    )
    try acceptSelfHostedSession(response)
  }

  @MainActor
  public func refreshSelfHostedSession() async throws {
    guard AppEnvironment.isSelfHosted else { return }
    let token: String? = try keychain.get(.token)
    guard token != nil else { return }
    do {
      let response: SelfHostedSession = try await client.request(path: "/v1/user/session", method: .get, parameters: nil)
      try acceptSelfHostedSession(response)
    } catch BookPlayerError.networkErrorWithCode(_, let code) where code == "self_hosted_session_expired" {
      try logout()
      throw AccountError.missingToken
    }
    // Connectivity errors intentionally preserve the cached capability and offline playback.
  }

  @MainActor
  private func acceptSelfHostedSession(_ response: SelfHostedSession) throws {
    guard response.selfHosted, !response.token.isEmpty, !response.accountId.isEmpty else {
      throw AccountError.missingToken
    }
    try keychain.set(response.token, key: .token)
    let cached = SelfHostedSession(token: response.token, accountId: response.accountId,
      email: response.email, selfHosted: true, server: Bundle.main.configurationString(for: .apiDomain))
    try keychain.set(cached, key: .selfHostedAccount)
    updateAccount(id: response.accountId, email: response.email, hasSubscription: true)
  }
}
