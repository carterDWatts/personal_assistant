"""Durable delivery between authenticated devices and one leased worker."""

import uuid

from engine.db import jsonb


class LeaseLost(RuntimeError):
    pass


class Relay:
    def __init__(self, map_, worker_id=None):
        self.map = map_
        self.worker_id = worker_id or uuid.uuid4()

    def owner_lock(self):
        owner = self.map.row('select * from assistant.owner for update')
        if not owner:
            raise RuntimeError('Bind an authenticated owner before starting the worker.')
        return owner['user_id']

    def check(self):
        if not self.map.value('select exists(select 1 from assistant.host where worker_id=%s'
                              ' and lease_until>clock_timestamp())', (self.worker_id,)):
            raise LeaseLost('Worker lease expired.')

    def acquire(self):
        with self.map.conn.transaction():
            owner = self.owner_lock()
            claimed = self.map.value(
                "insert into assistant.host(singleton,worker_id,seen_at,lease_until)"
                " values(true,%s,clock_timestamp(),clock_timestamp()+interval '60 seconds')"
                " on conflict(singleton) do update set worker_id=excluded.worker_id,"
                " seen_at=excluded.seen_at,lease_until=excluded.lease_until"
                " where assistant.host.lease_until<=clock_timestamp() returning worker_id", (self.worker_id,))
            if not claimed:
                return False
            # A crashed turn may already have performed an external action. Never replay it.
            for turn in self.map.rows("update assistant.turns set status='failed',finished_at=now()"
                                      " where status='running' returning id"):
                self.emit(owner, turn['id'], {'type': 'error', 'message':
                    'The host restarted. Check whether the last action completed before trying again.'})
                self.emit(owner, turn['id'], {'type': 'end', 'status': 'failed'})
            return True

    def heartbeat(self):
        with self.map.conn.transaction():
            self.owner_lock()
            self.check()
            self.map.execute("update assistant.host set seen_at=clock_timestamp(),"
                             " lease_until=clock_timestamp()+interval '60 seconds' where worker_id=%s", (self.worker_id,))

    def release(self):
        with self.map.conn.transaction():
            self.owner_lock()
            self.map.execute('update assistant.host set lease_until=clock_timestamp() where worker_id=%s', (self.worker_id,))

    def claim(self):
        with self.map.conn.transaction():
            owner = self.owner_lock()
            self.check()
            turn = self.map.row("update assistant.turns set status='running',worker_id=%s"
                                " where id=(select id from assistant.turns where status='queued' order by created_at limit 1)"
                                " returning *", (self.worker_id,))
            if turn:
                self.emit(owner, turn['id'], {'type': 'start'})
            return turn

    def emit(self, owner, turn, payload):
        return self.map.value('select assistant.emit(%s,%s,%s)', (owner, turn, jsonb(payload)))

    def day(self):
        return self.map.value('select assistant.day_snapshot()')

    def publish_day(self, day):
        with self.map.conn.transaction():
            owner = self.owner_lock()
            self.check()
            self.emit(owner, None, {'type': 'map', **day})
            text = ('Memory update paused; chat still works.' if day['errors'] else
                    'Updating memory in the background…' if day['pending'] else '')
            self.emit(owner, None, {'type': 'memory', 'text': text})

    def publish(self, turn, payloads):
        with self.map.conn.transaction():
            owner = self.owner_lock()
            self.check()
            active = self.map.value("select exists(select 1 from assistant.turns where id=%s"
                                    " and worker_id=%s and status='running')", (turn, self.worker_id))
            if not active:
                raise LeaseLost('Turn no longer belongs to this worker.')
            for payload in payloads:
                self.emit(owner, turn, payload)

    def cancelled(self, turn):
        self.check()
        return bool(self.map.value('select cancel_requested from assistant.turns where id=%s', (turn,)))

    def finish(self, turn, status):
        if status not in ('completed', 'cancelled', 'failed'):
            raise ValueError('Invalid terminal status')
        with self.map.conn.transaction():
            owner = self.owner_lock()
            self.check()
            # Cancellation wins if it committed before completion did.
            updated = self.map.row("update assistant.turns set status=case when cancel_requested then 'cancelled' else %s end,"
                                   " finished_at=now() where id=%s and worker_id=%s and status='running' returning status",
                                   (status, turn, self.worker_id))
            if not updated:
                raise LeaseLost('Turn no longer belongs to this worker.')
            self.emit(owner, turn, {'type': 'end', 'status': updated['status']})
