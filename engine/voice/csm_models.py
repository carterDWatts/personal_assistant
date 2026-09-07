"""Download the selected voice and its dependencies at pinned revisions."""
from pathlib import Path

ASSETS = {
    'csm': ('mlx-community/csm-1b', '5bf5ec118cf45fecc7b51198fd9f1a20a5aab65a', ['config.json', 'model.safetensors', 'README.md']),
    'tokenizer': ('unsloth/Llama-3.2-1B', '9535bd9b1d1dea6acafbdc4813b728796aeb28da', ['tokenizer*', 'special_tokens_map.json']),
    'codec': ('kyutai/moshiko-pytorch-bf16', '2bfc9ae6e89079a5cc7ed2a68436010d91a3d289', ['tokenizer-e351c8d8-checkpoint125.safetensors']),
    'reference': ('kyutai/tts-voices', '323332d33f997de8394f24a193e1a76df720e01a', ['expresso/ex01-ex02_default_001_channel1_168s.wav', 'README.md']),
}
REFERENCE_TEXT = 'The smell must have been atrocious. I mean, are you like, um, so in what I know about like'
# Playing at this rate preserves the audition's 0.75-semitone lowering and pace.
PLAYBACK_RATE = round(24000 * 2 ** (-0.75 / 12))


def directory():
    return Path.home() / '.personal-assistant' / 'models' / 'american-lower'


def asset(name):
    return directory() / name / ASSETS[name][1]


def install():
    from huggingface_hub import snapshot_download
    for name, (repo, revision, files) in ASSETS.items():
        snapshot_download(repo, revision=revision, allow_patterns=files, local_dir=asset(name), token=False)
    print(f'American Lower installed: {directory()}')


if __name__ == '__main__':
    install()
