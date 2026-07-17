#!/usr/bin/env python3
"""Zero-dependency validation for the public device-profile contract."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parent.parent
SCHEMA_PATH = ROOT / "specs" / "device-profile.schema.json"
PROFILE_DIR = ROOT / "device-profiles"


def load_json(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"{path}: top-level JSON value must be an object")
    return value


def validate_profile(path: Path, schema: dict) -> list[str]:
    profile = load_json(path)
    errors: list[str] = []

    required = set(schema["required"])
    allowed = set(schema["properties"])
    missing = sorted(required - set(profile))
    extra = sorted(set(profile) - allowed)
    if missing:
        errors.append(f"missing root fields: {', '.join(missing)}")
    if extra:
        errors.append(f"unknown root fields: {', '.join(extra)}")

    if profile.get("schemaVersion") != 1:
        errors.append("schemaVersion must equal 1")
    if not re.fullmatch(r"[a-z0-9]+([.-][a-z0-9]+)*", str(profile.get("id", ""))):
        errors.append("id must be a lowercase dotted-or-dashed identifier")

    statuses = set(schema["$defs"]["status"]["enum"])
    support = profile.get("support")
    if not isinstance(support, dict) or support.get("status") not in statuses:
        errors.append("support.status must use a schema status")
    elif not str(support.get("notes", "")).strip():
        errors.append("support.notes must be non-empty")

    identity = profile.get("identity")
    if not isinstance(identity, dict):
        errors.append("identity must be an object")
    else:
        names = identity.get("bluetoothNames", [])
        if not isinstance(names, list) or any(not str(name).strip() for name in names):
            errors.append("identity.bluetoothNames must be non-empty strings")
        if len(names) != len(set(names)):
            errors.append("identity.bluetoothNames must be unique")
        hid = identity.get("hid")
        if hid is not None:
            if not isinstance(hid, dict):
                errors.append("identity.hid must be an object")
            else:
                for field in ("vendorId", "productId"):
                    value = hid.get(field)
                    if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 65535:
                        errors.append(f"identity.hid.{field} must be a 16-bit integer")

    transport_schema = schema["properties"]["transports"]["items"]["properties"]
    transport_kinds = set(transport_schema["kind"]["enum"])
    transport_roles = set(transport_schema["role"]["enum"])
    transports = profile.get("transports")
    if not isinstance(transports, list) or not transports:
        errors.append("transports must be a non-empty array")
    else:
        for index, transport in enumerate(transports):
            if not isinstance(transport, dict):
                errors.append(f"transports[{index}] must be an object")
                continue
            if transport.get("kind") not in transport_kinds:
                errors.append(f"transports[{index}].kind is not in the schema")
            if transport.get("role") not in transport_roles:
                errors.append(f"transports[{index}].role is not in the schema")
            if transport.get("status") not in statuses:
                errors.append(f"transports[{index}].status is not in the schema")
            if not str(transport.get("notes", "")).strip():
                errors.append(f"transports[{index}].notes must be non-empty")

    capability_values = set(schema["properties"]["capabilities"]["items"]["enum"])
    capabilities = profile.get("capabilities")
    if not isinstance(capabilities, list) or not capabilities:
        errors.append("capabilities must be a non-empty array")
    elif any(value not in capability_values for value in capabilities):
        errors.append("capabilities contains a value outside the schema")
    elif len(capabilities) != len(set(capabilities)):
        errors.append("capabilities must be unique")

    platform_values = set(
        schema["properties"]["platforms"]["items"]["properties"]["platform"]["enum"]
    )
    platforms = profile.get("platforms")
    if not isinstance(platforms, list) or not platforms:
        errors.append("platforms must be a non-empty array")
    else:
        seen_platforms: set[str] = set()
        for index, platform in enumerate(platforms):
            if not isinstance(platform, dict):
                errors.append(f"platforms[{index}] must be an object")
                continue
            name = platform.get("platform")
            if name not in platform_values:
                errors.append(f"platforms[{index}].platform is not in the schema")
            elif name in seen_platforms:
                errors.append(f"platform {name} appears more than once")
            else:
                seen_platforms.add(name)
            if platform.get("status") not in statuses:
                errors.append(f"platforms[{index}].status is not in the schema")
            if not str(platform.get("notes", "")).strip():
                errors.append(f"platforms[{index}].notes must be non-empty")

    sources = profile.get("sources")
    if not isinstance(sources, list) or not sources:
        errors.append("sources must be a non-empty array")
    else:
        for index, source in enumerate(sources):
            parsed = urlparse(str(source))
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                errors.append(f"sources[{index}] must be an absolute HTTP(S) URL")

    return [f"{path.name}: {error}" for error in errors]


def main() -> int:
    schema = load_json(SCHEMA_PATH)
    profiles = sorted(PROFILE_DIR.glob("*.json"))
    if not profiles:
        print("FAIL no device profiles found", file=sys.stderr)
        return 1

    errors: list[str] = []
    for profile in profiles:
        try:
            errors.extend(validate_profile(profile, schema))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            errors.append(str(exc))

    if errors:
        for error in errors:
            print(f"FAIL {error}", file=sys.stderr)
        return 1

    print(f"PASS device profile contract profiles={len(profiles)} schemaVersion=1")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
