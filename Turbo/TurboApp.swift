//
//  TurboApp.swift
//  Turbo
//
//  Created by Maurice on 20.03.2026.
//

import SwiftUI
import UIKit
import AVFAudio

private enum AppAudioSessionBootstrapper {
    @MainActor
    static func configureCategoryForPushToTalk() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
        } catch {
            print("Failed to configure launch audio session category:", error.localizedDescription)
        }
    }
}

final class TurboAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        AppAudioSessionBootstrapper.configureCategoryForPushToTalk()
        Task { @MainActor in
            await PTTViewModel.shared.initializeIfNeeded()
        }
        return true
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
