"""Local British speech over JSON lines. Cancellation never reloads the model."""
import base64
import json
import queue
import sys
import threading

import numpy as np
import sherpa_onnx
from engine.voice.tts_models import directory


def create_voice():
    root=directory()
    config=sherpa_onnx.OfflineTtsConfig(model=sherpa_onnx.OfflineTtsModelConfig(
        kokoro=sherpa_onnx.OfflineTtsKokoroModelConfig(
            model=str(root/'model.onnx'), voices=str(root/'voices.bin'),
            tokens=str(root/'tokens.txt'), data_dir=str(root/'espeak-ng-data'),
            lexicon=str(root/'lexicon-gb-en.txt'), lang='en'), num_threads=2), max_num_sentences=1)
    if not config.validate(): raise RuntimeError('Voice model is missing. Rebuild the app.')
    return sherpa_onnx.OfflineTts(config)


def main():
    def emit(event): print(json.dumps(event),flush=True)
    pending=queue.Queue()
    cancelled=threading.Event()
    lock=threading.Lock()
    generation=0
    def read():
        nonlocal generation
        try:
            for line in sys.stdin:
                request=json.loads(line)
                if request.get('type')=='cancel':
                    with lock: generation+=1
                elif request.get('type')=='speak':
                    text=request.get('text','')
                    if not isinstance(text,str) or len(text)>20000: raise ValueError('Invalid speech request')
                    with lock: token=generation
                    pending.put((token,request))
        finally:
            cancelled.set(); pending.put(None)
    threading.Thread(target=read,daemon=True).start()
    try:
        voice=create_voice()
        emit({'type':'ready'})
        while item:=pending.get():
            token,request=item
            def current():
                with lock: return not cancelled.is_set() and token==generation
            if not current(): continue
            def audio(samples,progress):
                if not current(): return 0
                emit({'type':'audio','id':request['id'],'rate':voice.sample_rate,
                      'pcm':base64.b64encode(np.asarray(samples,dtype='<f4').tobytes()).decode()})
                return 1  # sherpa's native callback: 1 continues, 0 cancels.
            result=voice.generate(request['text'],sid=26,speed=1.0,callback=audio)
            if current() and not len(result.samples): raise RuntimeError('No speech generated')
            if current(): emit({'type':'done','id':request['id']})
    except Exception:
        emit({'type':'error','text':'Local voice failed. Check the voice model installation.'})
        return 1
    return 0


if __name__=='__main__': sys.exit(main())
