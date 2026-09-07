"""Install pinned Kokoro assets once. Model weights stay outside the repository."""
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import urllib.request

REPO = 'csukuangfj/kokoro-multi-lang-v1_0'
REVISION = '7e9b67b79bfdcbd2b4bc144370345fcceac3cb0c'


def directory():
    return Path.home()/'.personal-assistant'/'models'/REVISION


def install():
    root = directory()
    root.mkdir(parents=True, exist_ok=True)
    manifest = root/'manifest-american.json'
    if manifest.exists():
        files = json.loads(manifest.read_text())
    else:
        with urllib.request.urlopen(f'https://huggingface.co/api/models/{REPO}/tree/{REVISION}?recursive=true&limit=1000', timeout=60) as response:
            files = [f for f in json.load(response) if f['type']=='file' and (f['path'].startswith('espeak-ng-data/') or f['path'] in ['model.onnx','voices.bin','tokens.txt','lexicon-us-en.txt','LICENSE','README.md'])]
        manifest.write_text(json.dumps(files))
    def fetch(item):
        name = item['path']
        dest = root/name
        if dest.resolve().is_relative_to(root.resolve()) is False:
            raise ValueError('Invalid asset path')
        def valid(path):
            if not path.is_file(): return False
            data = path.read_bytes()
            if 'lfs' in item: return hashlib.sha256(data).hexdigest()==item['lfs']['oid']
            return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()==item['oid']
        if valid(dest): return
        dest.parent.mkdir(parents=True,exist_ok=True)
        temporary=dest.with_suffix(dest.suffix+'.download')
        try:
            url=f'https://huggingface.co/{REPO}/resolve/{REVISION}/'+urllib.parse.quote(name)
            urllib.request.urlretrieve(url,temporary)
            if not valid(temporary): raise RuntimeError(f'Voice asset checksum failed: {name}')
            temporary.replace(dest)
        finally: temporary.unlink(missing_ok=True)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(fetch, files))
    print(f'Voice model installed: {root}')


if __name__=='__main__': install()
