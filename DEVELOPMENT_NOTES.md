# Tevari implementation notes

## Glasses microphone troubleshooting

When a glasses voice flow misbehaves, begin with an existing Tevari flow that
works on the same hardware and compare the complete audio-session lifecycle
before diagnosing a platform limitation.

- Prayer is the reference implementation for glasses microphone capture.
- Clear the previous audio session before requesting the HFP glasses input.
- Establish and verify the route before sending the glasses listening screen.
- Keep Tevari's own `● Listening` card visible and update it with throttled
  partial transcription results.
- Do not conclude a limitation is permanent until the new flow has been
  tested with the same setup as the known-good reference flow.

The Story flow initially used a separate microphone setup, which triggered a
call-style surface. Matching Prayer's session cleanup and routing resolved it.
