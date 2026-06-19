#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import os
import time
from typing import Optional

import numpy as np
import soundfile as sf
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field
from faster_qwen3_tts import FasterQwen3TTS

SPEAKERS = ["aiden", "dylan", "eric", "ryan", "serena", "sohee", "uncle_fu", "vivian", "ono_anna"]

class SpeechRequest(BaseModel):
    model: Optional[str] = None
    input: str = Field(..., min_length=1)
    voice: Optional[str] = None
    language: Optional[str] = None
    instructions: Optional[str] = None
    instruct: Optional[str] = None
    response_format: str = "wav"
    stream: bool = False
    chunk_size: int = 8


def audio_array(x):
    if isinstance(x, list):
        return np.concatenate([audio_array(i).reshape(-1) for i in x]).astype(np.float32, copy=False)
    if hasattr(x, "detach"):
        x = x.detach().float().cpu().numpy()
    return np.squeeze(np.asarray(x)).astype(np.float32, copy=False).reshape(-1)


def wav_bytes(x, sr: int) -> bytes:
    buf = io.BytesIO()
    sf.write(buf, audio_array(x), int(sr), format="WAV")
    return buf.getvalue()


def pcm16_bytes(x) -> bytes:
    arr = np.clip(audio_array(x), -1.0, 1.0)
    return (arr * 32767.0).astype("<i2").tobytes()


class Runtime:
    def __init__(self, model_id: str, served_name: str, default_speaker: str, default_language: str):
        self.model_id = model_id
        self.served_name = served_name
        self.default_speaker = default_speaker
        self.default_language = default_language
        self.created = int(time.time())
        self.model = FasterQwen3TTS.from_pretrained(model_id)

    def speaker(self, requested: Optional[str]) -> str:
        speaker = requested or self.default_speaker
        if speaker not in SPEAKERS:
            raise HTTPException(status_code=400, detail=f"Unsupported speaker: {speaker}")
        return speaker

    def kwargs(self, req: SpeechRequest) -> dict:
        data = {"text": req.input, "language": req.language or self.default_language, "speaker": self.speaker(req.voice)}
        inst = req.instructions or req.instruct
        if inst:
            data["instruct"] = inst
        return data

    def generate(self, req: SpeechRequest):
        data = self.kwargs(req)
        try:
            return self.model.generate_custom_voice(**data)
        except TypeError:
            data["voice"] = data.pop("speaker")
            return self.model.generate_custom_voice(**data)

    def stream(self, req: SpeechRequest):
        data = self.kwargs(req)
        data["chunk_size"] = max(1, int(req.chunk_size or 8))
        try:
            iterator = self.model.generate_custom_voice_streaming(**data)
        except TypeError:
            data["voice"] = data.pop("speaker")
            iterator = self.model.generate_custom_voice_streaming(**data)
        for item in iterator:
            if isinstance(item, tuple) and len(item) >= 2:
                yield item[0], int(item[1])
            else:
                yield item, 24000


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8091)
    p.add_argument("--model", default="Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice")
    p.add_argument("--served-model-name", default="qwen3-tts-faster-customvoice")
    p.add_argument("--speaker", default=os.getenv("JARVIS_TTS_DEFAULT_SPEAKER", "aiden"))
    p.add_argument("--language", default=os.getenv("JARVIS_TTS_DEFAULT_LANGUAGE", "German"))
    args = p.parse_args()

    runtime = Runtime(args.model, args.served_model_name, args.speaker, args.language)
    app = FastAPI(title="Jarvis Faster Qwen3-TTS CustomVoice")

    @app.get("/health")
    def health():
        return {"status": "ok"}

    @app.get("/v1/models")
    def models():
        return {"object": "list", "data": [{"id": runtime.served_name, "object": "model", "created": runtime.created, "owned_by": "jarvis", "root": runtime.model_id, "parent": None}]}

    @app.get("/v1/audio/voices")
    def voices():
        return {"voices": SPEAKERS, "uploaded_voices": [], "default_voice": runtime.default_speaker, "mode": "customvoice", "model": runtime.model_id}

    @app.post("/v1/audio/speech")
    def speech(req: SpeechRequest):
        fmt = (req.response_format or "wav").lower()
        if fmt not in {"wav", "pcm"}:
            raise HTTPException(status_code=400, detail="Only wav and pcm are supported")
        if req.stream:
            def chunks():
                for audio, _sr in runtime.stream(req):
                    yield pcm16_bytes(audio)
            return StreamingResponse(chunks(), media_type="audio/pcm", headers={"X-Audio-Sample-Rate": "24000", "X-Jarvis-Stream-Format": "pcm_s16le"})
        audio, sr = runtime.generate(req)
        if fmt == "pcm":
            return Response(content=pcm16_bytes(audio), media_type="audio/pcm", headers={"X-Audio-Sample-Rate": str(sr)})
        return Response(content=wav_bytes(audio, sr), media_type="audio/wav")

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")

if __name__ == "__main__":
    main()
