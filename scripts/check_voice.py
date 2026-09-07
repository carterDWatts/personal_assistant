"""Exercise the real local recognizer with timed PCM, without a microphone or model API."""
import json
import queue
import re
import subprocess
import sys
import threading
import time
import wave
import numpy as np
from engine.voice.models import directory


def words(text):
    return re.findall(r"[a-z']+", text.lower())


def error_rate(reference, actual):
    ref, got = words(reference), words(actual)
    row = list(range(len(got)+1))
    for i, expected in enumerate(ref, 1):
        following = [i]
        for j, word in enumerate(got, 1):
            following.append(min(row[j]+1, following[-1]+1, row[j-1]+(word != expected)))
        row = following
    return row[-1]/max(1,len(ref))


def main():
    import struct
    root = directory()/'test_wavs'
    references = {}
    for line in (root/'trans.txt').read_text().splitlines():
        name, text = line.split(maxsplit=1)
        references[name.removesuffix('.wav')] = text
    process = subprocess.Popen([sys.executable,'-m','engine.voice.recognize'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    events = queue.Queue()
    def collect():
        for line in process.stdout:
            events.put((time.monotonic(),json.loads(line)))
    threading.Thread(target=collect,daemon=True).start()
    def send(rate, samples):
        process.stdin.write(struct.pack('<II',rate,len(samples))+samples.astype('<f4').tobytes())
        process.stdin.flush()
    try:
        _, ready = events.get(timeout=20)
        assert ready['type']=='ready', ready
        # Silence must not turn into a fabricated utterance.
        for _ in range(100):
            send(16000,np.zeros(320,dtype=np.float32))
            time.sleep(0.02)
        time.sleep(0.3)
        assert events.empty(), 'Recognition invented text during silence'
        results = []
        for name in ['0','1']:
            with wave.open(str(root/(name+'.wav'))) as wav:
                assert wav.getnchannels()==1 and wav.getsampwidth()==2
                rate=wav.getframerate()
                samples=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').astype(np.float32)/32768
            duration=len(samples)/rate
            padded=np.concatenate([samples,np.zeros(rate*2,dtype=np.float32)])
            step=int(rate*0.02)
            started=time.monotonic()
            for offset in range(0,len(padded),step):
                send(rate,padded[offset:offset+step])
                time.sleep(max(0,started+(offset+step)/rate-time.monotonic()))
            partials=[]; finals=[]
            while True:
                try: at,event=events.get(timeout=0.2)
                except queue.Empty: break
                assert event['type']!='error',event
                if event['type']=='partial':partials.append((at-started,event['text']))
                if event['type']=='final':finals.append(event['text'])
            text=' '.join(finals)
            wer=error_rate(references[name],text)
            assert partials and 0<=partials[0][0]<duration, ('No live partial',name,partials)
            assert finals and wer<=0.25, (name,wer,text)
            results.append({'clip':name,'seconds':round(duration,2),'first_partial_seconds':round(partials[0][0],2),'partial_updates':len(partials),'word_error_rate':round(wer,3),'text':text})
        print(json.dumps({'passed':True,'tests':results},indent=2))
    finally:
        process.stdin.close()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()


if __name__=='__main__':
    main()
