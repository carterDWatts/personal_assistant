"""Check real local synthesis, interruption and reuse without a speaker or paid API."""
import base64
import json
import queue
import subprocess
import sys
import threading
import time
import wave

import numpy as np


def main():
    process=subprocess.Popen([sys.executable,'-m','engine.voice.synthesize'],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
    events=queue.Queue()
    def collect():
        for line in process.stdout: events.put(json.loads(line))
    threading.Thread(target=collect,daemon=True).start()
    def send(event):
        process.stdin.write((json.dumps(event)+'\n').encode());process.stdin.flush()
    def receive():
        event=events.get(timeout=30)
        assert event['type']!='error',event
        return event
    try:
        assert receive()['type']=='ready'
        started=time.monotonic()
        send({'type':'speak','id':'sample','text':'Good morning, Carter. How did you sleep? We can take a moment to figure out what matters most today.'})
        chunks=[];first=None;available=0;underruns=0
        while (event:=receive())['type']!='done':
            if event['type']=='started': continue
            assert event['type']=='audio' and event['id']=='sample',event
            if first is None:first=time.monotonic()-started
            assert event['rate']==event_rate
            chunk=np.frombuffer(base64.b64decode(event['pcm']),dtype='<f4')
            assert len(chunk)>0 and np.isfinite(chunk).all()
            at=time.monotonic()-started
            if available and at>available+0.05: underruns+=1
            available=max(available,at)+len(chunk)/event_rate
            chunks.append(chunk)
        samples=np.concatenate(chunks);seconds=len(samples)/event_rate
        assert np.max(np.abs(samples))>0.01
        assert first < 2 and underruns == 0, (first, underruns)
        print(json.dumps({"first_audio_seconds": round(first,2), "audio_seconds": round(seconds,2)}), flush=True)
        # Interrupt active synthesis, then speak again with the same loaded model.
        send({'type':'speak','id':'old','text':'This sentence should be interrupted. '*4})
        while (event:=receive())['type'] != 'started':
            assert event.get('id') == 'old', event
        time.sleep(0.1)
        send({'type':'cancel'})
        restart=time.monotonic()
        send({'type':'speak','id':'new','text':'Of course. What would you like to change?'})
        new_audio=False
        resumed_first=None
        while True:
            event=receive()
            if event.get('id')=='new':
                if event['type']=='audio':
                    new_audio=True
                    if resumed_first is None: resumed_first=time.monotonic()-restart
                if event['type']=='done':break
        assert new_audio and time.monotonic()-restart<5
        if len(sys.argv)>1:
            with wave.open(sys.argv[1],'wb') as wav:
                wav.setparams((1,2,event_rate,0,'NONE','not compressed'))
                wav.writeframes((samples.clip(-1,1)*32767).astype('<i2').tobytes())
        print(json.dumps({'passed':True,'first_audio_seconds':round(first,2),'audio_seconds':round(seconds,2),'cancel_and_resume':True,'buffer_underruns':underruns,'resumed_audio_seconds':round(resumed_first,2)}))
    finally:
        process.stdin.close()
        try:process.wait(timeout=5)
        except subprocess.TimeoutExpired:process.kill();process.wait()


event_rate=24000
if __name__=='__main__':main()
