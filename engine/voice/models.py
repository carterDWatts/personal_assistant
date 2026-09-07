"""Versioned speech assets. Download once; recognition never uses the network."""
import hashlib
import os
from pathlib import Path
import urllib.request

REPO = 'csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26'
REVISION = '672fbf1b30579d6585301139bb363f42a0ad4a24'
HASHES = {
    'encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx':'563fde436d16cf7607cf408cd6b30909819d03162652ef389c2450ced3f45ac1',
    'decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx':'98da299f471e38bb4e1a8df579b8cc9122d6039576a77e357b3c60f17dd83b02',
    'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx':'d944208d660d67c8d72cd2acaeac971fa5ceb8c80e76c1968148846fedd6e297',
}
FILES = ['encoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx', 'decoder-epoch-99-avg-1-chunk-16-left-128.int8.onnx',
         'joiner-epoch-99-avg-1-chunk-16-left-128.int8.onnx', 'tokens.txt']


def directory():
    return Path(os.environ.get('ASSISTANT_SPEECH_MODEL', Path.home()/'.personal-assistant'/'models'/REVISION))


def install():
    target = directory()
    target.mkdir(parents=True, exist_ok=True)
    for name in FILES + ['README.md', 'test_wavs/0.wav', 'test_wavs/1.wav', 'test_wavs/trans.txt']:
        dest = target/name
        if dest.exists() and (name not in HASHES or hashlib.sha256(dest.read_bytes()).hexdigest() == HASHES[name]):
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        temporary = dest.with_suffix(dest.suffix + '.download')
        try:
            urllib.request.urlretrieve(f'https://huggingface.co/{REPO}/resolve/{REVISION}/{name}', temporary)
            if name in HASHES and hashlib.sha256(temporary.read_bytes()).hexdigest() != HASHES[name]:
                raise RuntimeError(f"Speech model checksum failed: {name}")
            temporary.replace(dest)
        finally:
            temporary.unlink(missing_ok=True)
    print(f'Speech model installed: {target}')


if __name__ == '__main__':
    install()
