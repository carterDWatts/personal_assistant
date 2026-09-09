"""Public connection definitions shared by the host, gateway and Apple apps."""
import json
from pathlib import Path

_DATA = json.loads((Path(__file__).resolve().parents[2] / "shared/integrations.json").read_text())
if _DATA["version"] != 1:
    raise RuntimeError("Unsupported integration catalog version")
PROVIDERS = {item["id"]: item for item in _DATA["providers"]}
GOOGLE_GRANTS = {item["id"]: item for item in PROVIDERS["google"]["grants"]}
ACCOUNT_PROVIDERS = {key: item for key, item in PROVIDERS.items() if key != "google"}
OAUTH_PROVIDERS = {key: item for key, item in ACCOUNT_PROVIDERS.items() if item["auth"] == "oauth"}
