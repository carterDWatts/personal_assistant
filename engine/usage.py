"""Content-free accounting for background inference, outside the knowledge map."""
import time
import uuid
from engine.db import jsonb


def record(map_, kind, runtime, metrics, started, input_chars=0):
    map_.execute("insert into assistant.source_items(source,id,payload,processed_at) values('runtime-usage',%s,%s,now())",
                 (str(uuid.uuid4()), jsonb({'kind':kind,'runtime':runtime,'metrics':metrics.as_dict() if metrics else None,
                                          'seconds':round(time.monotonic()-started,2),'input_chars':input_chars})))
