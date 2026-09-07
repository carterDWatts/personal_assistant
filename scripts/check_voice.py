"""Exercise the real local recognizer with timed PCM, without a microphone or model API."""
import json
import queue
import re
import subprocess
import sys
import threading
import time
import wave
import tempfile
import shutil
from pathlib import Path
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
    fixtures = tempfile.TemporaryDirectory(prefix='assistant-speech-check-')
    cases = [(name, root/(name+'.wav'), 1, references[name], .25) for name in ['0','1']]
    if shutil.which('say') and shutil.which('afconvert'):
        phrase = 'How quickly does this take input?'
        recording = Path(fixtures.name)/'input'
        subprocess.run(['say','-v','Samantha','-r','190','-o',str(recording.with_suffix('.aiff')),phrase],check=True)
        subprocess.run(['afconvert','-f','WAVE','-d','LEI16@48000',str(recording.with_suffix('.aiff')),str(recording.with_suffix('.wav'))],check=True)
        cases += [(f'input-{gain}', recording.with_suffix('.wav'), gain, phrase, 0) for gain in [1,.1]]
        parts = []
        for index, text in enumerate(['How quickly', 'does this take input?']):
            part = Path(fixtures.name)/str(index)
            subprocess.run(['say','-v','Samantha','-r','190','-o',str(part.with_suffix('.aiff')),text],check=True)
            subprocess.run(['afconvert','-f','WAVE','-d','LEI16@48000',str(part.with_suffix('.aiff')),str(part.with_suffix('.wav'))],check=True)
            with wave.open(str(part.with_suffix('.wav'))) as wav:
                pcm = np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2')
            voiced = np.flatnonzero(np.abs(pcm.astype(np.int32)) > 160)
            parts.append(pcm[max(0,voiced[0]-240):voiced[-1]+240])
        paused = Path(fixtures.name)/'paused.wav'
        with wave.open(str(paused),'wb') as wav:
            wav.setparams((1,2,48000,0,'NONE','not compressed'))
            wav.writeframes(np.concatenate([parts[0],np.zeros(38400,dtype='<i2'),parts[1]]).astype('<i2').tobytes())
        cases.append(('input-pause',paused,1,phrase,0))
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
        # Resetting a warm recognizer acknowledges readiness without restarting it.
        for _ in range(2):
            process.stdin.write(struct.pack('<II',0,0)); process.stdin.flush()
            _, ready = events.get(timeout=2)
            assert ready['type']=='ready', ready
        # Silence must not turn into a fabricated utterance.
        for _ in range(100):
            send(16000,np.zeros(320,dtype=np.float32))
            time.sleep(0.02)
        time.sleep(0.3)
        assert events.empty(), 'Recognition invented text during silence'
        results = []
        for name,path,gain,reference,max_error in cases:
            with wave.open(str(path)) as wav:
                assert wav.getnchannels()==1 and wav.getsampwidth()==2
                rate=wav.getframerate()
                samples=np.frombuffer(wav.readframes(wav.getnframes()),dtype='<i2').astype(np.float32)/32768
            samples *= gain
            duration=len(samples)/rate
            padded=np.concatenate([samples,np.zeros(rate*3,dtype=np.float32)])
            step=int(rate*0.02)
            started=time.monotonic()
            for offset in range(0,len(padded),step):
                send(rate,padded[offset:offset+step])
                time.sleep(max(0,started+(offset+step)/rate-time.monotonic()))
            partials=[]; finals=[]; final_times=[]
            while True:
                try: at,event=events.get(timeout=0.2)
                except queue.Empty: break
                assert event['type']!='error',event
                if event['type']=='partial':partials.append((at-started,event['text']))
                if event['type']=='final':
                    finals.append(event['text']); final_times.append(at-started)
            text=' '.join(finals)
            wer=error_rate(reference,text)
            assert partials and 0<=partials[0][0]<duration, ('No live partial',name,partials)
            assert finals and wer<=max_error, (name,wer,text)
            if name.startswith('input-'): assert len(finals)==1, ('Speech split too early', finals)
            last_voice = np.flatnonzero(np.abs(samples) > .005*gain)
            end_delay = final_times[-1] - last_voice[-1]/rate if len(last_voice) else None
            results.append({'end_delay_seconds':round(end_delay,2) if end_delay is not None else None,'clip':name,'seconds':round(duration,2),'first_partial_seconds':round(partials[0][0],2),'partial_updates':len(partials),'word_error_rate':round(wer,3),'text':text})
        print(json.dumps({'passed':True,'tests':results},indent=2))
    finally:
        fixtures.cleanup()
        process.stdin.close()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill();process.wait()


if __name__=='__main__':
    main()
