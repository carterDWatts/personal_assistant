#!/usr/bin/env python3
"""The assistant.

Usage:
  python3 assistant.py talk        continue the conversation
  python3 assistant.py morning     the assistant starts the morning session
  python3 assistant.py snapshot    print the map snapshot the assistant would receive
  python3 assistant.py status      recent sessions with their cost

Add --test to any command to use the test map instead of the real one.

Environment:
  ASSISTANT_DATABASE_URL           the knowledge map (Supabase session pooler URI)
  ASSISTANT_TEST_DATABASE_URL      the test map, used with --test or ASSISTANT_ENV=test
  ASSISTANT_MODEL                  model for the runtime, default claude-opus-5
  ASSISTANT_EFFORT                 low, medium or high, default medium
  ASSISTANT_SESSION_BUDGET_USD     hard cap per session, default 2.00
  ASSISTANT_DEVICE                 name of this device, default the hostname
"""

import asyncio
import os
import sys


def main(argv):
    if "--test" in argv:
        os.environ["ASSISTANT_ENV"] = "test"
        argv = [a for a in argv if a != "--test"]
    if not argv or argv[0] not in ("talk", "morning", "snapshot", "status"):
        print(__doc__.strip())
        return 1
    from engine import config
    from engine.db import Map
    if config.ENV == "test":
        print("[test map]")
    try:
        map_ = Map()
    except RuntimeError as e:
        print(e)
        return 2
    try:
        if argv[0] == "snapshot":
            from engine import context
            print(context.snapshot(map_))
            return 0
        if argv[0] == "status":
            for r in map_.rows("select agent, device, started_at, ended_at, ended_by, metrics from memory.conversations order by started_at desc limit 10"):
                m = r["metrics"] or {}
                print(f"{r['started_at']:%Y-%m-%d %H:%M} {r['agent']:8} {r['device']:10} {r['ended_by'] or 'open':8} "
                      f"${m.get('cost_usd', 0):.3f} {m.get('turns', 0)} turns")
            return 0
        from engine import engine, io, runtime
        rt = runtime.load(config.RUNTIME)()
        asyncio.run(engine.run(argv[0], map_, rt, io.Terminal(), config.DEVICE))
        return 0
    finally:
        map_.close()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
