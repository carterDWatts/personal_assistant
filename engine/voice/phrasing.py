"""Keep speech readable and preserve phrase boundaries without another model call."""
import re


def spoken(text):
    text = re.sub(r'!\[[^]]*\]\([^)]*\)', '', text)
    text = re.sub(r'\[([^]]+)\]\([^)]*\)', r'\1', text)
    text = re.sub(r'https?://\S+', '', text)
    text = re.sub(r'(?m)^\s*(?:#{1,6}\s+|[-*+]\s+|\d+[.)]\s+|>\s*)', '', text)
    text = re.sub(r'[*_`#]', '', text)
    text = re.sub(r'\s+[—–]\s+', ', ', text)
    return re.sub(r'\s+', ' ', text).strip()


def protected_boundary(text, end):
    # Keep Markdown links together so neither their URL nor half their label is read.
    for url in re.finditer(r'https?://\S*', text):
        if url.start() < end < url.end(): return url.start()
    opening = text.rfind('[',0,end)
    if opening >= 0:
        closing = text.find(')',opening)
        if closing < 0 or closing >= end: return opening
    return end


def phrase(buffer, flush=False, limit=180):
    for match in re.finditer(r'[.!?\n](?:\s+|$)', buffer):
        end=match.end()
        if end>limit: break
        prefix=buffer[:match.start()+1]
        if re.search(r'\b(?:Mr|Mrs|Ms|Dr|Prof|St|vs|etc)\.$',prefix,re.I): continue
        if re.search(r'\b(?:[A-Za-z]\.)+$',prefix): continue
        if protected_boundary(buffer,end)!=end: continue
        return buffer[:end].strip(),buffer[end:]
    if len(buffer)>=limit:
        # A comma or semicolon gives the voice a useful phrase rather than an arbitrary cutoff.
        candidates=list(re.finditer(r'[,;:]\s+',buffer[:limit]))
        end=candidates[-1].end() if candidates and candidates[-1].end()>=limit//2 else buffer.rfind(' ',0,limit)
        end=protected_boundary(buffer,end)
        if end>0: return buffer[:end].strip(),buffer[end:].lstrip()
    if flush and buffer.strip(): return buffer.strip(),''
    return None,buffer


def trim_padding(samples, rate, text):
    """Remove model-added edge silence, retaining breaths and punctuation pauses."""
    import numpy as np
    if len(samples)<rate//10: return samples
    threshold=max(.0005,float(np.max(np.abs(samples)))*.002)
    active=np.flatnonzero(np.abs(samples)>threshold)
    if not len(active): return samples
    lead=int(rate*.035)
    tail=int(rate*(.14 if re.search(r'[.!?][\"\u201d]?$',text.rstrip()) else .075))
    return samples[max(0,active[0]-lead):min(len(samples),active[-1]+tail+1)]
