"""Transcribe a bounded PCM WAV chunk with the installed local speech models."""
import json
import sys
import wave
import numpy as np
from engine.voice.recognize import Recognizer


def transcribe(path, recognizer=None):
    recognizer = recognizer or Recognizer()
    parts, pending = [], ''
    with wave.open(str(path), 'rb') as source:
        if source.getsampwidth() != 2 or source.getnchannels() > 8 or source.getnframes()/source.getframerate() > 60:
            raise ValueError('Expected a PCM16 chunk of at most one minute')
        rate, channels = source.getframerate(), source.getnchannels()
        while frame := source.readframes(rate//2):
            samples = np.frombuffer(frame, dtype='<i2').astype(np.float32).reshape(-1, channels).mean(axis=1)/32768
            for event in recognizer.accept(rate, samples):
                if event['type'] == 'final': parts.append(event['text']); pending = ''
                elif event['type'] == 'partial': pending = event['text']
        for event in recognizer.accept(rate, np.zeros(rate*3, dtype=np.float32)):
            if event['type'] == 'final': parts.append(event['text']); pending = ''
            elif event['type'] == 'partial': pending = event['text']
    if pending: parts.append(pending)
    return ' '.join(parts)


if __name__ == '__main__':
    print(json.dumps({'text': transcribe(sys.argv[1])}), flush=True)
