"""Streaming offline transcription. Input: <sample rate, sample count> + float32 PCM.

Output is JSON lines: ready, partial, final, error. No database or LLM access.
"""
import json
import re
import struct
import sys

import numpy as np
import sherpa_onnx
from engine.voice.models import directory, FILES
from engine.voice.final_models import directory as final_directory, FILES as FINAL_FILES


class Recognizer:
    def __init__(self):
        root = directory()
        if not all((root/name).is_file() for name in FILES):
            raise RuntimeError('Speech model is missing. Run python3 -m engine.voice.models once.')
        self.decoder = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=str(root/FILES[3]), encoder=str(root/FILES[0]), decoder=str(root/FILES[1]),
            joiner=str(root/FILES[2]), num_threads=2, sample_rate=16000, feature_dim=80,
            decoding_method='greedy_search', enable_endpoint_detection=True,
            rule1_min_trailing_silence=10, rule2_min_trailing_silence=0.7,
            rule3_min_utterance_length=30)
        self.stream = self.decoder.create_stream()
        self.previous = ''
        root = final_directory()
        self.final_decoder = sherpa_onnx.OnlineRecognizer.from_transducer(
            tokens=str(root/FINAL_FILES[3]), encoder=str(root/FINAL_FILES[0]),
            decoder=str(root/FINAL_FILES[1]), joiner=str(root/FINAL_FILES[2]),
            num_threads=2, decoding_method='greedy_search')
        self.audio = []
        self.rate = None

    def accept(self, rate, samples):
        if not 8000 <= rate <= 192000 or not np.isfinite(samples).all():
            raise ValueError('Invalid audio frame')
        if self.rate is not None and self.rate != rate:
            self.stream = self.decoder.create_stream()
            self.previous = ''
            self.audio = []
        self.rate = rate
        self.audio.append(samples.copy())
        self.stream.accept_waveform(rate, samples)
        while self.decoder.is_ready(self.stream):
            self.decoder.decode_stream(self.stream)
        text = self.decoder.get_result(self.stream).strip()
        # This model emits capitals without punctuation. Display sentence case while typing.
        if text.isupper():
            text = re.sub(r"\bi\b", "I", text.capitalize())
        events = []
        if text and text != self.previous:
            events.append({'type':'partial', 'text':text})
            self.previous = text
        if self.decoder.is_endpoint(self.stream):
            if text:
                verified = self.final_decoder.create_stream()
                verified.accept_waveform(rate, np.concatenate(self.audio))
                verified.accept_waveform(rate, np.zeros(rate*3, dtype=np.float32))
                verified.input_finished()
                while self.final_decoder.is_ready(verified):
                    self.final_decoder.decode_stream(verified)
                final = self.final_decoder.get_result(verified).strip()
                events.append({'type':'final', 'text':final or text})
            self.stream = self.decoder.create_stream()
            self.audio = []
            self.previous = ''
        return events


def read_exact(stream, size):
    parts = bytearray()
    while len(parts) < size:
        chunk = stream.read(size-len(parts))
        if not chunk:
            if parts:
                raise ValueError('Truncated audio frame')
            return None
        parts.extend(chunk)
    return parts


def emit(event):
    print(json.dumps(event), flush=True)


def main():
    try:
        recognizer = Recognizer()
        emit({'type':'ready'})
        while header := read_exact(sys.stdin.buffer, 8):
            rate, count = struct.unpack('<II', header)
            if not 1 <= count <= 192000:
                raise ValueError('Invalid audio frame size')
            data = read_exact(sys.stdin.buffer, count*4)
            if data is None:
                raise ValueError('Missing audio samples')
            for event in recognizer.accept(rate, np.frombuffer(data, dtype='<f4')):
                emit(event)
    except Exception as error:
        emit({'type':'error', 'text':str(error) if isinstance(error, (RuntimeError, ValueError)) else 'Local speech recognition failed.'})
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
