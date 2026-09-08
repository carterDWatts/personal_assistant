"""CPU streaming speech; no speech API or per-word billing."""
import numpy as np
import torch
from pocket_tts import TTSModel


class PocketVoice:
    def __init__(self, voice='michael'):
        torch.set_num_threads(2)
        self.model = TTSModel.load_model(language='english_2026-04',temp=.3)
        self.state = self.model.get_state_for_audio_prompt(voice)
        self.sample_rate = self.model.sample_rate

    def stream(self, text, cancelled):
        pending=[]
        size=0
        target=int(self.sample_rate*.32)
        for chunk in self.model.generate_audio_stream(self.state,text,copy_state=True):
            if cancelled.is_set(): return
            samples=chunk.detach().cpu().numpy().reshape(-1)
            pending.append(samples); size+=len(samples)
            if size>=target:
                yield np.concatenate(pending)
                pending=[];size=0;target=int(self.sample_rate*.96)
        if pending and not cancelled.is_set(): yield np.concatenate(pending)
