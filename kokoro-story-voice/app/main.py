"""Private Kokoro narration service for Tevari Story.

Cloud Run IAM is the service boundary: this application must not be deployed
publicly. It accepts only Tevari-generated narration text and curated Kokoro
voices; it deliberately has no voice-cloning or reference-audio capability.
"""

from __future__ import annotations

from io import BytesIO
from threading import Lock
import re

import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException
from kokoro import KPipeline
from pydantic import BaseModel, Field


SAMPLE_RATE = 24_000
MAX_TEXT_CHARACTERS = 2_400
MAX_CHUNK_CHARACTERS = 900
DEFAULT_VOICE = "af_bella"
ALLOWED_VOICES = {DEFAULT_VOICE}

app = FastAPI(title="Tevari Story Voice", version="0.1.0", docs_url=None, redoc_url=None)
pipeline = KPipeline(lang_code="a")
synthesis_lock = Lock()


class NarrationRequest(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_TEXT_CHARACTERS)
    voice: str = DEFAULT_VOICE
    speed: float = Field(default=0.96, ge=0.8, le=1.15)


def split_for_narration(text: str) -> list[str]:
    """Keep requests in Kokoro's reliable mid-length narration range."""
    sentences = re.split(r"(?<=[.!?])\s+", " ".join(text.split()))
    chunks: list[str] = []
    current = ""
    for sentence in sentences:
        if not sentence:
            continue
        if len(sentence) > MAX_CHUNK_CHARACTERS:
            raise HTTPException(422, "A story sentence is too long to narrate safely.")
        proposed = f"{current} {sentence}".strip()
        if current and len(proposed) > MAX_CHUNK_CHARACTERS:
            chunks.append(current)
            current = sentence
        else:
            current = proposed
    if current:
        chunks.append(current)
    if not chunks:
        raise HTTPException(422, "Narration text cannot be empty.")
    return chunks


def synthesize(request: NarrationRequest) -> bytes:
    if request.voice not in ALLOWED_VOICES:
        raise HTTPException(422, "That narrator voice is not available.")

    audio_parts: list[np.ndarray] = []
    with synthesis_lock:
        for chunk in split_for_narration(request.text):
            for _, _, audio in pipeline(chunk, voice=request.voice, speed=request.speed):
                audio_parts.append(np.asarray(audio, dtype=np.float32))

    if not audio_parts:
        raise HTTPException(502, "The narrator did not produce audio.")

    # A brief natural pause separates internally chunked story narration.
    pause = np.zeros(int(SAMPLE_RATE * 0.18), dtype=np.float32)
    combined = np.concatenate([part for pair in zip(audio_parts, [pause] * len(audio_parts)) for part in pair][:-1])
    output = BytesIO()
    sf.write(output, combined, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    return output.getvalue()


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "engine": "kokoro-82m", "defaultVoice": DEFAULT_VOICE}


@app.post("/v1/narrations", responses={200: {"content": {"audio/wav": {}}}})
def narrate(request: NarrationRequest):
    from fastapi.responses import Response

    audio = synthesize(request)
    return Response(
        content=audio,
        media_type="audio/wav",
        headers={
            "Cache-Control": "private, no-store",
            "X-Tevari-Narrator": request.voice,
        },
    )
