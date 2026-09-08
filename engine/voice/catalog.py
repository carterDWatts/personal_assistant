"""Stable voice IDs backed by trusted Pocket TTS reference samples."""
VOICES = [
    {'id': 'michael', 'name': 'Michael · American', 'source': 'michael'},
    {'id': 'bill', 'name': 'Bill · American', 'source': 'bill_boerst'},
    {'id': 'british', 'name': 'Stuart · British', 'source': 'stuart_bell'},
]

def choices():
    return [{k: v[k] for k in ('id', 'name')} for v in VOICES]
