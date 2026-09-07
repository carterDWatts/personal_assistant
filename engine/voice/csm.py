"""Mac speech adapter. All model assets are local before the worker starts."""
import contextlib
import os
import sys

from engine.voice.csm_models import asset, REFERENCE_TEXT


def create_voice():
    os.environ['HF_HUB_OFFLINE'] = '1'
    os.environ['TRANSFORMERS_OFFLINE'] = '1'
    os.environ['HF_HUB_DISABLE_IMPLICIT_TOKEN'] = '1'
    import mlx.core as mx
    from mlx_audio.codec.models.mimi.mimi import Mimi, mimi_202407
    from mlx_audio.tts.models.sesame import sesame
    from mlx_audio.tts.utils import load_model

    class LocalMimi(Mimi):
        @classmethod
        def from_pretrained(cls, repo_id, filename='tokenizer-e351c8d8-checkpoint125.safetensors'):
            model = cls(mimi_202407(32))
            model.load_pytorch_weights(str(asset('codec') / filename), strict=True)
            mx.eval(model.parameters())
            return model

    # mlx-audio 0.5.2 hardcodes remote dependency names. Bind its loader to
    # our pinned local assets only while constructing this worker's model.
    original_mimi, original_tokenizer = sesame.Mimi, sesame.TOKENIZER_REPO
    try:
        sesame.Mimi = LocalMimi
        sesame.TOKENIZER_REPO = str(asset('tokenizer'))
        with contextlib.redirect_stdout(sys.stderr):
            model = load_model(asset('csm'))
    finally:
        sesame.Mimi, sesame.TOKENIZER_REPO = original_mimi, original_tokenizer
    return model


def generate(voice, text, current=lambda: True):
    import mlx.core as mx
    mx.random.seed(42)
    # Bound each context to the model's sequence limit without dropping text.
    import textwrap
    for part in textwrap.wrap(text, width=350, break_long_words=True):
        if not current(): return
        yield from voice.generate(
            text=part,
            ref_audio=str(asset('reference') / 'expresso/ex01-ex02_default_001_channel1_168s.wav'),
            ref_text=REFERENCE_TEXT, voice_match=False,
            stream=True, streaming_interval=0.5, max_audio_length_ms=30000,
        )
