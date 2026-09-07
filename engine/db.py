"""Direct Postgres access to the knowledge map.

Everything the engine reads comes from the views and everything it writes goes
through the SQL functions, so this layer stays thin: a connection, a few query
helpers, and a way to call a function by name with named arguments.
"""

import json
import uuid
from datetime import date, datetime
from decimal import Decimal

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb
from psycopg.types.range import Range

from engine import config


class Map:
    def __init__(self, url=None):
        self.url = url or config.DATABASE_URL
        if not self.url:
            name = "ASSISTANT_TEST_DATABASE_URL" if config.ENV == "test" else "ASSISTANT_DATABASE_URL"
            raise RuntimeError(f"{name} is not set")
        self.conn = psycopg.Connection.connect(self.url, row_factory=dict_row, autocommit=True)  # type: ignore[arg-type]
        # Dates the database computes must agree with the device the user is on.
        self.conn.execute("select set_config('timezone', %s, false)", (config.TIMEZONE,))

    def close(self):
        self.conn.close()

    def rows(self, sql, params=None):
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    def row(self, sql, params=None):
        rows = self.rows(sql, params)
        return rows[0] if rows else None

    def value(self, sql, params=None):
        r = self.row(sql, params)
        return next(iter(r.values())) if r else None

    def call(self, fn, **args):
        """Call a memory function that returns a row, with named arguments."""
        named = ", ".join(f"{k} => %({k})s" for k in args)
        return self.row(f"select * from memory.{fn}({named})", args)

    def call_value(self, fn, **args):
        """Call a memory function that returns a scalar."""
        named = ", ".join(f"{k} => %({k})s" for k in args)
        return self.value(f"select memory.{fn}({named}) as value", args)

    def execute(self, sql, params=None):
        with self.conn.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount


def jsonb(value):
    return Jsonb(value)


def encode(obj):
    """JSON encoder for rows coming out of Postgres."""
    if isinstance(obj, (datetime, date)):
        return obj.isoformat()
    if isinstance(obj, uuid.UUID):
        return str(obj)
    if isinstance(obj, Decimal):
        return float(obj)
    if isinstance(obj, Range):
        return {"from": encode(obj.lower) if obj.lower else None, "to": encode(obj.upper) if obj.upper else None}
    if isinstance(obj, bytes):
        return obj.decode("utf-8", "replace")
    return str(obj)


def dumps(data):
    return json.dumps(data, default=encode, ensure_ascii=False, sort_keys=True)
