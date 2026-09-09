"""Encrypt browser commands before they enter the relay. Never log their contents."""
import base64
import json
import os
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

b64=lambda value:base64.b64encode(value).decode()

def seal(public_key, payload, command_id):
    key=AESGCM.generate_key(bit_length=256);iv=os.urandom(12)
    public=serialization.load_pem_public_key(public_key.encode())
    encrypted=public.encrypt(key,padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
    data=AESGCM(key).encrypt(iv,json.dumps(payload).encode(),str(command_id).encode())
    return json.dumps({'key':b64(encrypted),'iv':b64(iv),'data':b64(data)})

def unseal(private, envelope, command_id):
    value=json.loads(envelope)
    key=private.decrypt(base64.b64decode(value['key']),padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
    return json.loads(AESGCM(key).decrypt(base64.b64decode(value['iv']),base64.b64decode(value['data']),str(command_id).encode()))
