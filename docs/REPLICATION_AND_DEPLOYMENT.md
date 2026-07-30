# Replicating and deploying Tevari

This guide describes the production-shaped setup used by Tevari. It is deliberately explicit about security boundaries: mobile clients never contain Gloo or YouVersion secrets, and the narration container is private.

Read [the project README](../README.md) first for the product architecture and integration roles.

## 1. Prerequisites

- macOS with current Xcode and a physical iPhone.
- A Firebase project with Authentication enabled.
- Firebase CLI and Node.js 22 (the Functions runtime is Node 22).
- A Google Cloud project connected to Firebase, with Cloud Run enabled.
- Gloo AI credentials for server-to-server OAuth.
- A YouVersion Platform app key with permission to retrieve the desired Bible translation.
- A Meta Wearables developer project, supported Meta display glasses, Meta AI app, and access to the iOS Device Access Toolkit (DAT).
- Docker or Cloud Build access to build the Kokoro narration image.

## 2. Repository layout and sensitive values

The complete reviewable source lives in this repository. The Firebase Functions source is at [`backend/functions`](../backend/functions), and its Firebase configuration is at [`backend/firebase.json`](../backend/firebase.json). These are source-only files: credentials and local environment files are intentionally excluded. A development workspace may keep a sibling `functions/` working directory, but it must remain synchronized with this repository copy before review or deployment.

Do not put any of the following in source control or `Info.plist`:

| Value | Where it belongs |
| --- | --- |
| Gloo client ID and client secret | Firebase Functions secrets |
| YouVersion Platform app key | Firebase Functions secret |
| Firebase service credentials | Firebase-managed configuration / `GoogleService-Info.plist` supplied by Firebase |
| Meta client token | Meta’s supported application configuration, only if the current DAT setup requires it |
| Cloud Run identity credentials | Google IAM, not a downloaded key file |

The included `.gitignore` excludes local build outputs. Add any local environment files or service-account keys to it before creating them.

## 3. Firebase Authentication

In Firebase Console:

1. Create or select a Firebase project.
2. Add the iOS app using the bundle identifier configured in Xcode.
3. Download `GoogleService-Info.plist` and replace the project file in `Tevari/` locally. Treat it as environment-specific configuration.
4. Enable the providers your product exposes: Anonymous/Guest and Google sign-in at minimum.
5. Complete the Google iOS OAuth configuration and add the reversed client-ID URL scheme to the app target. The project’s `Info.plist` already demonstrates the expected URL-scheme structure.

All callable endpoints require a Firebase ID token. The app gets it from the signed-in Firebase user before calling the backend.

## 4. Firebase Functions + Gloo + YouVersion

From the repository root:

```bash
firebase login
firebase use YOUR_FIREBASE_PROJECT_ID
cd backend/functions
pnpm install
firebase functions:secrets:set GLOO_CLIENT_ID
firebase functions:secrets:set GLOO_CLIENT_SECRET
firebase functions:secrets:set YVP_APP_KEY
```

The functions are HTTP endpoints in [`backend/functions/src/index.js`](../backend/functions/src/index.js), deployed to `us-central1`:

| Endpoint | Job |
| --- | --- |
| `prayerContinue` | Direct prayer continuation + licensed passage |
| `faithLens` | Image/question reflection + licensed passage |
| `parallel` | Scripture-account retrieval + licensed passage shelf |
| `storyScene` | Structured story scene + licensed passage |
| `storyNarration` | Authenticated proxy to private Cloud Run narration |
| `scripturePassage` | Retrieves a selected licensed YouVersion passage |

### Gloo configuration

Tevari exchanges `GLOO_CLIENT_ID` and `GLOO_CLIENT_SECRET` for a short-lived OAuth token at Gloo’s token endpoint. Functions then call the Gloo chat-completions API with `auto_routing: true` and send the selected provider-supported tradition when applicable.

When implementing a new feature, keep these rules intact:

1. Ask Gloo for bounded structured data, never ready-to-display Scripture.
2. Validate the structured response in Functions.
3. Convert/validate any passage reference to the expected USFM form.
4. Retrieve displayable Bible text from YouVersion.
5. Keep generated prose visibly distinct from Scripture in the UI.

### YouVersion configuration

Set `YVP_APP_KEY` as a Firebase secret. `licensedScripture` currently retrieves from YouVersion Bible ID `111` (NIV11). If a different translation is authorized, change the Bible constant and verify its license/attribution requirements before release.

### Deploy Functions

First deploy the voice service (next section). Then provide the non-secret
`STORY_VOICE_URL` parameter when Firebase prompts during deployment (or through
your approved Firebase parameter environment workflow) and deploy Functions.
Use the `deploy` script in [`backend/functions/package.json`](../backend/functions/package.json) if your Firebase project
is already selected:

```bash
pnpm run deploy
```

After deployment, set `TevariAPIBaseURL` in the iOS app’s `Info.plist` to the Firebase HTTPS base URL for the same project/region. The shipped development configuration uses the `us-central1` base URL pattern.

## 5. Private Kokoro narration service on Cloud Run

The voice service is at `kokoro-story-voice/`. Its Docker image prefetches Kokoro-82M during the image build so the first user does not pay the model-download delay.

From this repository root, build and deploy it. Replace the placeholders with your project and region:

```bash
gcloud config set project YOUR_GOOGLE_CLOUD_PROJECT_ID
gcloud artifacts repositories create tevari \
  --repository-format=docker \
  --location=REGION

gcloud builds submit Tevari/kokoro-story-voice \
  --tag REGION-docker.pkg.dev/YOUR_GOOGLE_CLOUD_PROJECT_ID/tevari/voice:latest

gcloud run deploy tevari-story-voice \
  --image REGION-docker.pkg.dev/YOUR_GOOGLE_CLOUD_PROJECT_ID/tevari/voice:latest \
  --region REGION \
  --no-allow-unauthenticated
```

Grant the Firebase/Functions runtime service account permission to invoke this Cloud Run service:

```bash
gcloud run services add-iam-policy-binding tevari-story-voice \
  --region REGION \
  --member="serviceAccount:YOUR_FUNCTIONS_RUNTIME_SERVICE_ACCOUNT" \
  --role="roles/run.invoker"
```

Set the resulting HTTPS service URL as the Functions parameter (the name is `STORY_VOICE_URL`) using the Firebase CLI/parameter workflow appropriate to the installed Firebase CLI version, then redeploy the Functions. The function obtains an OIDC identity token with `GoogleAuth`; no static Cloud Run key is needed.

Verify the service only while authenticated:

```bash
gcloud run services describe tevari-story-voice --region REGION --format='value(status.url)'
```

Do not make the service public. It accepts no voice cloning or reference audio and returns `Cache-Control: private, no-store`.

## 6. Meta display glasses setup (DAT)

### Xcode project

The Tevari target depends on the Meta DAT Swift packages:

- `MWDATCore`
- `MWDATDisplay`
- `MWDATCamera`

Confirm the resolved package version is supported by your Meta developer program. The app initializes the SDK in `TevariApp.swift` with `Wearables.configure()` and routes DAT callbacks via `Wearables.shared.handleUrl(_:)`.

### Meta developer configuration

In the Meta Wearables developer portal for your project:

1. Register the iOS app with its exact bundle identifier and Apple Team ID.
2. Configure the app-link callback to match Tevari’s custom scheme: `tevari://`.
3. Enable the display and any approved camera/microphone capabilities.
4. Provide the user-facing rationales Meta requires for camera/microphone requests.
5. Install the required Meta AI/glasses component and any DAT update on the paired glasses.

In `Info.plist`, keep the `MWDAT` configuration aligned with the portal. Confirm `TeamID`, `MetaAppID`, callback scheme, accessory protocol, and privacy usage descriptions before running on hardware. Never copy another developer’s Meta configuration or token into this app.

### Hardware validation flow

1. Pair and update the glasses in Meta AI.
2. Open Tevari on the signed-in iPhone.
3. Choose **Glasses** and explicitly start a display session.
4. Confirm the first glasses surface renders and that the selected faith background is visible.
5. Test each flow: Prayer listening, Faith Lens camera + spoken question, Story prompt + narration, Parallel prompt + passage shelf.
6. Confirm audio output/input route returns to the glasses after narration and that the UI remains Tevari’s own listening card rather than an unexpected system call surface.
7. End the session and verify camera/microphone use stops.

`DEVELOPMENT_NOTES.md` contains the microphone troubleshooting approach that proved reliable: compare any failing flow against the known-good Prayer lifecycle, reset the prior audio session, establish the desired route before listening, and update a throttled transcript card.

### Distribution constraint

DAT availability and allowed distribution can change. Before any TestFlight or App Store upload, confirm the current Meta Wearables documentation and your program terms. A phone-only build can be configured independently; do not assume a build containing external-accessory/DAT integration is eligible for Apple distribution without explicit current approval.

## 7. iOS setup and app capabilities

Open `Tevari.xcodeproj` in Xcode and set:

1. A unique bundle identifier and your Apple Development Team.
2. The matching Firebase iOS configuration file.
3. `TevariAPIBaseURL` for your deployed Firebase Functions base URL.
4. The matching Meta DAT app configuration (after portal registration).
5. Camera, microphone, speech recognition, Bluetooth, local-network, and external-accessory declarations only if the corresponding functionality remains in the target.

The project supports portrait and landscape on iPhone/iPad. It includes Siri App Intents for opening the **iPhone** Prayer, Faith Lens, Story, and Parallel experiences. Siri intentionally does not initiate glasses access—hardware sessions remain a conscious on-screen action.

## 8. Validation checklist

### Backend

- `pnpm run lint` succeeds in `backend/functions/`.
- Function rejects unauthenticated requests.
- A Gloo response cannot expose raw JSON/markdown in the app.
- A malformed/invalid Gloo passage reference does not cause generated text to be shown as Scripture.
- Every rendered passage has a YouVersion reference and translation attribution.
- Cloud Run narration endpoint rejects unauthenticated requests.

### Phone experience

- Guest sign-in and Google sign-in work; sign-out and account deletion handle the active provider correctly.
- All four experiences show a loading state while awaiting a backend response.
- Composer text clears after send; images clear after Faith Lens submission.
- Keyboard dismisses when the person taps outside an active composer.
- Story changes from “Preparing narration” to a narrating state once audio playback begins.
- Shortcuts open the requested iPhone module.

### Glasses experience

- Every listening path (initial and retry) shows Tevari’s listening/transcript UI.
- Faith Lens asks for camera access only after explicit user action.
- Story continuation uses the current scene’s Scripture anchor rather than a fixed passage.
- Narration is coherent audio and plays through the desired active route.
- Stopping a glasses session releases camera, microphone, playback, and display resources.

## 9. Release hygiene

- Increment the Xcode build number for each uploaded build.
- Update the privacy manifest and App Privacy answers whenever data practices change.
- Host a stable public privacy-policy URL; a private Google Drive link is not a suitable public App Store privacy-policy URL.
- Provide Apple review notes with test credentials and exact instructions for the available experience. Do not describe Meta glasses functionality as publicly distributable until your current approvals confirm it.
- Keep Gloo, YouVersion, Firebase, Cloud Run, and Meta credentials out of Git history.
