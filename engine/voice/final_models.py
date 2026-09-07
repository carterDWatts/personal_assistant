"""Pinned Kroko assets for verifying completed utterances locally."""
import hashlib
from pathlib import Path
import urllib.request

REPO = 'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06'
REVISION = '572aaf4e2e0c603c3fc2a574d096e755a178faa1'
HASHES = {'encoder.onnx': 'd4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4', 'decoder.onnx': '455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1', 'joiner.onnx': 'd406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52', 'tokens.txt': '396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d'}
FILES = ['encoder.onnx', 'decoder.onnx', 'joiner.onnx', 'tokens.txt']


def directory():
    return Path.home()/'.personal-assistant'/'models'/REVISION


def install():
    target = directory()
    target.mkdir(parents=True, exist_ok=True)
    for name in FILES + ['README.md']:
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
