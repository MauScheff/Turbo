//
//  TurboApp.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI
import UIKit
import AVFAudio
import UserNotifications

private enum AppRuntimeEnvironment {
    static var isRunningAutomatedTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

private enum AppAudioSessionBootstrapper {
    @MainActor
    static func configureCategoryForPushToTalk() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: MediaSessionAudioPolicy.routeCapableOptions
            )
        } catch {
            print("Failed to configure launch audio session category:", error.localizedDescription)
        }
    }
}

enum TurboNotificationCategory {
    static let talkRequest = "TURBO_TALK_REQUEST"
    static let acceptTalkRequestAction = "TURBO_ACCEPT_TALK_REQUEST"
    static let notNowTalkRequestAction = "TURBO_NOT_NOW_TALK_REQUEST"

    struct DeliveredNotificationSnapshot {
        let identifier: String
        let categoryIdentifier: String
        let userInfo: [AnyHashable: Any]
    }

    static func register(on center: UNUserNotificationCenter = .current()) {
        let accept = UNNotificationAction(
            identifier: acceptTalkRequestAction,
            title: "Connect",
            options: [.foreground]
        )
        let notNow = UNNotificationAction(
            identifier: notNowTalkRequestAction,
            title: "Not Now",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: talkRequest,
            actions: [accept, notNow],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    static func shouldCompleteTalkRequestResponseAfterHandling(actionIdentifier: String) -> Bool {
        true
    }

    static func deliveredTalkRequestNotificationIdentifiers(
        from deliveredNotifications: [DeliveredNotificationSnapshot]
    ) -> [String] {
        deliveredNotifications.compactMap { notification in
            guard isTalkRequestNotification(
                categoryIdentifier: notification.categoryIdentifier,
                userInfo: notification.userInfo
            ) else {
                return nil
            }
            return notification.identifier
        }
    }

    static func clearDeliveredTalkRequestNotifications(
        deliveredNotifications: [DeliveredNotificationSnapshot],
        additionalIdentifiers: [String] = [],
        removeDeliveredIdentifiers: ([String]) -> Void,
        setBadgeCount: (Int) -> Void
    ) {
        let identifiers = Array(
            Set(
                deliveredTalkRequestNotificationIdentifiers(from: deliveredNotifications)
                + additionalIdentifiers
            )
        )
        if !identifiers.isEmpty {
            removeDeliveredIdentifiers(identifiers)
        }
        setBadgeCount(0)
    }

    static func clearDeliveredTalkRequestNotifications(
        including additionalIdentifiers: [String] = [],
        on center: UNUserNotificationCenter = .current()
    ) {
        center.getDeliveredNotifications { notifications in
            let deliveredNotifications = notifications.map {
                DeliveredNotificationSnapshot(
                    identifier: $0.request.identifier,
                    categoryIdentifier: $0.request.content.categoryIdentifier,
                    userInfo: $0.request.content.userInfo
                )
            }
            clearDeliveredTalkRequestNotifications(
                deliveredNotifications: deliveredNotifications,
                additionalIdentifiers: additionalIdentifiers,
                removeDeliveredIdentifiers: { center.removeDeliveredNotifications(withIdentifiers: $0) },
                setBadgeCount: { center.setBadgeCount($0) }
            )
        }
    }

    static func isTalkRequestNotification(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> Bool {
        categoryIdentifier == talkRequest || (userInfo["event"] as? String) == "talk-request"
    }
}

final class TurboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        AppAudioSessionBootstrapper.configureCategoryForPushToTalk()
        UNUserNotificationCenter.current().delegate = self
        TurboNotificationCategory.register()
        TurboNotificationCategory.clearDeliveredTalkRequestNotifications()
        Task { @MainActor in
            await PTTViewModel.shared.initializeIfNeeded()
            if !AppRuntimeEnvironment.isRunningAutomatedTests {
                await PTTViewModel.shared.configureAlertNotificationsIfNeeded()
            }
        }
        return true
    }

    func applicationWillEnterForeground(_ application: UIApplication) {
        TurboNotificationCategory.clearDeliveredTalkRequestNotifications()
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        TurboNotificationCategory.clearDeliveredTalkRequestNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { @MainActor in
            PTTViewModel.shared.handleReceivedAlertPushToken(deviceToken)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Task { @MainActor in
            PTTViewModel.shared.handleFailedToRegisterForRemoteNotifications(error)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if (userInfo["event"] as? String) == "talk-request" {
            TurboNotificationCategory.clearDeliveredTalkRequestNotifications(
                including: [notification.request.identifier],
                on: center
            )
            completionHandler([])
            Task { @MainActor in
                await PTTViewModel.shared.handleForegroundTalkRequestNotification(userInfo: userInfo)
            }
            return
        }
        completionHandler([.banner, .sound, .badge])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if (userInfo["event"] as? String) == "talk-request" {
            TurboNotificationCategory.clearDeliveredTalkRequestNotifications(
                including: [response.notification.request.identifier],
                on: center
            )
            let completesAfterHandling =
                TurboNotificationCategory.shouldCompleteTalkRequestResponseAfterHandling(
                    actionIdentifier: response.actionIdentifier
                )
            Task { @MainActor in
                await PTTViewModel.shared.handleTalkRequestNotificationResponse(
                    actionIdentifier: response.actionIdentifier,
                    userInfo: userInfo
                )
                if completesAfterHandling {
                    completionHandler()
                }
            }
            return
        }
        completionHandler()
    }
}

@main
struct TurboApp: App {
    @UIApplicationDelegateAdaptor(TurboAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: .shared)
        }
    }
}
