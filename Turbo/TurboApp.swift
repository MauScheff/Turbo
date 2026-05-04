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

final class TurboAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        AppAudioSessionBootstrapper.configureCategoryForPushToTalk()
        UNUserNotificationCenter.current().delegate = self
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
            Task { @MainActor in
                await PTTViewModel.shared.handleForegroundTalkRequestNotification(userInfo: userInfo)
            }
            completionHandler([])
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
            Task { @MainActor in
                await PTTViewModel.shared.handleTalkRequestNotificationResponse(userInfo: userInfo)
                completionHandler()
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
