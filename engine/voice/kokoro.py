"""Fast local American speech. Finish each sentence before handing it to playback."""
from types import SimpleNamespace
import re
import sherpa_onnx
from engine.voice.tts_models import directory


def create_voice():
    root = directory()
    config = sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
        kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
            model=str(root/'model.onnx'), voices=str(root/'voices.bin'),
            tokens=str(root/'tokens.txt'), data_dir=str(root/'espeak-ng-data'),
            lexicon=str(root/'lexicon-us-en.txt'), lang='en-us'), num_threads=2), max_num_sentences=1)
    if not config.validate(): raise RuntimeError('Voice model is missing. Rebuild the app.')
    return sherpa_onnx.OfflineTts(config)


def generate(voice, text, current=lambda: True):
    # Michael is speaker 16 in the pinned multilingual Kokoro v1.0 model.
    for sentence in re.split(r'(?<=[.!?])\s+', text.strip()):
        if not current(): return
        result = voice.generate(sentence, sid=16, speed=1.1,
                                callback=lambda samples, progress: int(current()))
        if current():
            yield SimpleNamespace(audio=result.samples)
