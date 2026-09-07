"""Local American speech over JSON lines. Cancellation never reloads the model."""
import base64
import json
import queue
import sys
import threading

import numpy as np
from engine.voice.csm import create_voice, generate
from engine.voice.tts_models import PLAYBACK_RATE


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
            produced = False
            stream = generate(voice, request['text'])
            try:
                for result in stream:
                    if not current(): break
                    samples = np.asarray(result.audio, dtype='<f4').reshape(-1)
                    if not len(samples): continue
                    if not np.isfinite(samples).all(): raise RuntimeError('Invalid speech audio')
                    produced = True
                    emit({'type':'audio','id':request['id'],'rate':PLAYBACK_RATE,
                          'pcm':base64.b64encode(samples.tobytes()).decode()})
            finally:
                stream.close()
            if current() and request['text'].strip() and not produced:
                raise RuntimeError('No speech generated')
            if current(): emit({'type':'done','id':request['id']})
    except Exception:
        emit({'type':'error','text':'Local voice failed. Check the voice model installation.'})
        return 1
    return 0


if __name__=='__main__': sys.exit(main())
