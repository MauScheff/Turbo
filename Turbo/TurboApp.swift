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
}

final class TurboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        AppAudioSessionBootstrapper.configureCategoryForPushToTalk()
        UNUserNotificationCenter.current().delegate = self
        TurboNotificationCategory.register()
        Task { @MainActor in
            await PTTViewModel.shared.initializeIfNeeded()
            if !AppRuntimeEnvironment.isRunningAutomatedTests {
                await PTTViewModel.shared.configureAlertNotificationsIfNeeded()
            }
        }
        return true
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
            center.removeAllDeliveredNotifications()
            center.setBadgeCount(0)
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
            center.removeAllDeliveredNotifications()
            center.setBadgeCount(0)
            let completesAfterHandling = response.actionIdentifier == TurboNotificationCategory.notNowTalkRequestAction
            if !completesAfterHandling {
                completionHandler()
            }
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
