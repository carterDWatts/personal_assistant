"""Paths, environment and the few tunables the engine needs.

Secrets come from the environment only. The connection string never lives in the repo.
"""

import os
import socket
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTS = ROOT / "prompts"

# ASSISTANT_ENV=test points everything at the test map so the real one only ever holds real life.
ENV = os.environ.get("ASSISTANT_ENV", "prod")
if ENV not in ("prod", "test"):
    raise ValueError("ASSISTANT_ENV must be prod or test")
DATABASE_URL = os.environ.get("ASSISTANT_TEST_DATABASE_URL" if ENV == "test" else "ASSISTANT_DATABASE_URL")
MODEL = os.environ.get("ASSISTANT_MODEL", "claude-opus-5")
EFFORT = os.environ.get("ASSISTANT_EFFORT", "medium")
DEVICE = os.environ.get("ASSISTANT_DEVICE", socket.gethostname().split(".")[0])
SESSION_BUDGET_USD = float(os.environ.get("ASSISTANT_SESSION_BUDGET_USD", "2.00"))
SEED_MESSAGES = 30


def _local_timezone():
    """The IANA name of this machine's zone, so the database's dates match the device's."""
    try:
        target = os.readlink("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return "UTC"


TIMEZONE = os.environ.get("ASSISTANT_TIMEZONE") or _local_timezone()


def prompt(name):
    return (PROMPTS / f"{name}.md").read_text()

RUNTIME = os.environ.get("ASSISTANT_RUNTIME", "claude-agent-sdk")
