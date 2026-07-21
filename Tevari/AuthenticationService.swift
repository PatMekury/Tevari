//
//  AuthenticationService.swift
//  Tevari
//

import Combine
import FirebaseAuth
import Foundation
import GoogleSignIn
import UIKit

@MainActor
final class AuthenticationService: ObservableObject {
    @Published private(set) var user: User?
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?

    init() {
        user = Auth.auth().currentUser
    }

    func signIn(email: String, password: String) async -> Bool {
        await perform {
            self.user = try await Auth.auth().signIn(withEmail: email, password: password).user
        }
    }

    func createAccount(name: String, email: String, password: String) async -> Bool {
        await perform {
            let result = try await Auth.auth().createUser(withEmail: email, password: password)
            let update = result.user.createProfileChangeRequest()
            update.displayName = name
            try await update.commitChanges()
            self.user = result.user
        }
    }

    func sendPasswordReset(email: String) async -> Bool {
        await perform {
            try await Auth.auth().sendPasswordReset(withEmail: email)
        }
    }

    func continueAsGuest() async -> Bool {
        await perform {
            self.user = try await Auth.auth().signInAnonymously().user
        }
    }

    func signInWithGoogle() async -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let presenter = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
            errorMessage = "Unable to open Google sign-in."
            return false
        }

        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let idToken = result.user.idToken?.tokenString else { throw AuthError.missingGoogleToken }
            let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: result.user.accessToken.tokenString)
            user = try await Auth.auth().signIn(with: credential).user
            return true
        } catch {
            errorMessage = (error as NSError).localizedDescription
            return false
        }
    }

    func signOut() throws {
        try Auth.auth().signOut()
        user = nil
    }

    private func perform(_ operation: () async throws -> Void) async -> Bool {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            try await operation()
            return true
        } catch {
            errorMessage = message(for: error)
            return false
        }
    }

    private func message(for error: Error) -> String {
        let error = error as NSError

        switch error.code {
        case 17004:
            return "This email does not have a password sign-in yet. Continue with Google, or create an email/password account with a different email."
        case 17007:
            return "An account already exists for this email. Use the sign-in method you originally chose."
        case 17009:
            return "That email or password is incorrect."
        case 17011:
            return "No account exists for that email. Create an account first."
        default:
            return error.localizedDescription
        }
    }
}

private enum AuthError: LocalizedError { case missingGoogleToken }
