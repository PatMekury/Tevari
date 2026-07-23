//
//  TevariAPI.swift
//  Tevari
//
//  TestFlight API boundary. Credentials stay in Firebase Functions, never here.
//

import FirebaseAuth
import Foundation

enum TevariAPIError: LocalizedError {
    case notConfigured
    case notSignedIn
    case invalidResponse
    case service(message: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Tevari's secure service is not configured for this build yet."
        case .notSignedIn:
            return "Sign in to Tevari before using this feature."
        case .invalidResponse:
            return "Tevari received an unexpected response."
        case .service(let message):
            return message
        }
    }
}

struct PrayerHistoryItem: Codable, Sendable {
    let role: String
    let content: String

    static func spoken(_ content: String) -> PrayerHistoryItem {
        PrayerHistoryItem(role: "user", content: content)
    }
}

struct TevariPrayerPrompt: Decodable, Sendable {
    struct Scripture: Decodable, Sendable {
        struct Bible: Decodable, Sendable {
            let id: Int
            let title: String
            let abbreviation: String
            let copyright: String?
            let publisherURL: URL?
            let deepLink: URL?
        }

        let id: String
        let reference: String
        let content: String
        let bible: Bible
    }

    let prompt: String
    let scripture: Scripture
    let model: String?
}

/// A Faith Lens response always keeps generated reflection separate from the
/// licensed Scripture supplied by YouVersion.
struct TevariFaithLensResponse: Decodable, Sendable {
    let response: String
    let prayer: String?
    let scripture: TevariPrayerPrompt.Scripture
    let model: String?
}

/// A single guided Story scene. `narration` and `guide` are Tevari-generated;
/// `scripture` remains the separately licensed and attributed source text.
struct TevariStoryScene: Decodable, Sendable {
    let title: String
    let guide: String
    let narration: String
    let scripture: TevariPrayerPrompt.Scripture
    let model: String?
}

struct TevariScripturePassage: Decodable, Sendable {
    struct Passage: Decodable, Sendable {
        let id: String
        let reference: String
        let content: String
    }

    struct Bible: Decodable, Sendable {
        let id: Int
        let title: String
        let abbreviation: String
        let copyright: String?
        let info: String?
        let publisherURL: URL?
        let deepLink: URL?
    }

    let passage: Passage
    let bible: Bible
}

enum TevariAPI {
    static func prayerContinuation(
        history: [PrayerHistoryItem],
        tradition: String
    ) async throws -> TevariPrayerPrompt {
        try await request(
            path: "prayerContinue",
            body: [
                "history": history.map { ["role": $0.role, "content": $0.content] },
                "tradition": tradition
            ]
        )
    }

    static func scripturePassage(
        bibleID: Int,
        passageID: String
    ) async throws -> TevariScripturePassage {
        try await request(
            path: "scripturePassage",
            body: ["bibleID": bibleID, "passageID": passageID]
        )
    }

    static func faithLens(
        imageData: Data,
        question: String,
        tradition: String = "general"
    ) async throws -> TevariFaithLensResponse {
        try await request(
            path: "faithLens",
            body: [
                "imageBase64": imageData.base64EncodedString(),
                "question": question,
                "tradition": tradition
            ]
        )
    }

    static func storyScene(
        prompt: String,
        tradition: String = "general",
        continuationPassageID: String? = nil
    ) async throws -> TevariStoryScene {
        var body: [String: Any] = ["prompt": prompt, "tradition": tradition]
        if let continuationPassageID { body["continuationPassageID"] = continuationPassageID }
        return try await request(
            path: "storyScene",
            body: body
        )
    }

    static func storyNarration(_ narration: String) async throws -> Data {
        guard let baseURLString = Bundle.main.object(forInfoDictionaryKey: "TevariAPIBaseURL") as? String,
              !baseURLString.isEmpty,
              let baseURL = URL(string: baseURLString),
              baseURL.scheme == "https" else {
            throw TevariAPIError.notConfigured
        }
        guard let user = Auth.auth().currentUser else {
            throw TevariAPIError.notSignedIn
        }

        let token = try await user.getIDToken()
        var request = URLRequest(url: baseURL.appending(path: "storyNarration"))
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["narration": narration])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TevariAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder().decode(ServiceError.self, from: data)
            throw TevariAPIError.service(message: error?.error.message ?? "Tevari's story narrator is unavailable.")
        }
        let payload: StoryNarrationPayload
        do {
            payload = try JSONDecoder().decode(StoryNarrationPayload.self, from: data)
        } catch {
            throw TevariAPIError.invalidResponse
        }
        guard let audio = Data(base64Encoded: payload.audioBase64),
              audio.count >= 44,
              String(data: audio.prefix(4), encoding: .ascii) == "RIFF",
              String(data: audio.dropFirst(8).prefix(4), encoding: .ascii) == "WAVE" else {
            throw TevariAPIError.invalidResponse
        }
        return audio
    }

    private static func request<Response: Decodable>(path: String, body: [String: Any]) async throws -> Response {
        guard let baseURLString = Bundle.main.object(forInfoDictionaryKey: "TevariAPIBaseURL") as? String,
              !baseURLString.isEmpty,
              let baseURL = URL(string: baseURLString),
              baseURL.scheme == "https" else {
            throw TevariAPIError.notConfigured
        }
        guard let user = Auth.auth().currentUser else {
            throw TevariAPIError.notSignedIn
        }

        let token = try await user.getIDToken()
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TevariAPIError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let error = try? JSONDecoder().decode(ServiceError.self, from: data)
            throw TevariAPIError.service(message: error?.error.message ?? "Tevari's secure service is unavailable.")
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw TevariAPIError.invalidResponse
        }
    }

    private struct ServiceError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }

    private struct StoryNarrationPayload: Decodable {
        let audioBase64: String
    }
}
