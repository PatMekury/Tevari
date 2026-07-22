# Tevari Story Voice

Private, Cloud Run-ready narration service for Tevari Story. It uses the
Apache-2.0 licensed Kokoro-82M model and the curated `af_bella` narrator.
It accepts text only; voice cloning and reference audio are intentionally not
implemented.

## Contract

`POST /v1/narrations`

```json
{
  "text": "Esther stood before the king with courage.",
  "voice": "af_bella",
  "speed": 0.96
}
```

The service returns `audio/wav` at 24 kHz. It does not persist requests or
audio and marks responses `private, no-store`.

## Deployment boundary

Deploy this service as an authenticated Cloud Run service. Do **not** use
`--allow-unauthenticated`: the Tevari backend will call it with a Cloud Run
identity token after it has generated a story scene from Gloo and retrieved
the corresponding licensed YouVersion passage.

Before production release, validate the selected voice against Tevari's
accessibility, pronunciation, attribution, and cultural-quality requirements.
