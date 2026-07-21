//
//  TevariApp.swift
//  Tevari
//
//  Created by Patrick Obumselu on 7/18/26.
//

import SwiftUI
import FirebaseCore
import GoogleSignIn
import MWDATCore

@main
struct TevariApp: App {
    init() {
        FirebaseApp.configure()
        if let clientID = FirebaseApp.app()?.options.clientID {
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        }
        do { try Wearables.configure() } catch { assertionFailure("Meta glasses setup failed: \(error)") }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Controls respect safe areas, while the visual canvas continues
                // behind the status bar and Dynamic Island.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.tevariMidnight.ignoresSafeArea())
				.ignoresSafeArea(.container, edges: .all)
				.onOpenURL { url in
					_ = GIDSignIn.sharedInstance.handle(url)
					Task {
						do {
							let handled = try await Wearables.shared.handleUrl(url)
							print("Tevari DAT callback handled: \(handled)")
						} catch {
							print("Tevari DAT callback failed: \(error.localizedDescription)")
						}
					}
				}
        }
    }
}
