# SPDX-License-Identifier: Unlicense
"""Deterministic helpers shared by update and compatibility workflows."""

from __future__ import annotations

import base64
import json
import re
import shlex
from pathlib import Path


BUILD_ID = re.compile(r"^[1-9][0-9]{5,19}$")
STATE_MARKER = re.compile(r"<!-- bg3-build-state:v1 build=([1-9][0-9]*) -->")


def parse_public_build_id(text: str) -> str:
    """Parse only depots/branches/public/buildid from Steam KeyValues output."""
    stack: list[str] = []
    pending: str | None = None
    values: list[str] = []
    token = re.compile(r'^\s*"([^"]+)"(?:\s+"([^"]*)")?\s*$')
    for raw in text.splitlines():
        line = raw.strip()
        matched = token.match(line)
        if matched:
            key, value = matched.groups()
            if value is None:
                pending = key
            elif stack[-3:] == ["depots", "branches", "public"] and key == "buildid":
                values.append(value)
            continue
        if line == "{" and pending is not None:
            stack.append(pending)
            pending = None
        elif line == "}" and stack:
            stack.pop()
    unique = sorted(set(values))
    if len(unique) != 1 or not BUILD_ID.fullmatch(unique[0]):
        raise ValueError("expected exactly one decimal depots.branches.public.buildid")
    return unique[0]


def decide_build_change(detected: str, state_body: str | None, baseline: str | None) -> tuple[str, str]:
    if not BUILD_ID.fullmatch(detected):
        raise ValueError("detected build ID is invalid")
    if state_body is not None:
        matches = STATE_MARKER.findall(state_body)
        if len(matches) != 1:
            raise ValueError("existing state issue must contain exactly one marker")
        previous = matches[0]
    else:
        previous = baseline
    if previous is not None and not BUILD_ID.fullmatch(previous):
        raise ValueError("baseline build ID is invalid")
    if previous is None:
        return "bootstrap", detected
    return ("unchanged" if previous == detected else "changed"), previous


def initial_state_build(decision: str, previous: str, detected: str) -> str:
    """Do not acknowledge a changed build before notification succeeds."""
    if decision not in {"bootstrap", "unchanged", "changed"}:
        raise ValueError("invalid watcher decision")
    return previous if decision == "changed" else detected


def validate_evidence(value: object, expected_build: str | None = None,
                      expected_executable: str | None = None) -> dict:
    if not isinstance(value, dict):
        raise ValueError("evidence root must be an object")
    allowed = {"schema", "collector", "collected_at_utc", "steam_build_id",
               "executable", "sections", "anchors", "validation"}
    if set(value) != allowed:
        raise ValueError("evidence root fields differ from the v1 schema")
    if value["schema"] != "best-of-hands-compatibility-evidence.v1":
        raise ValueError("unsupported evidence schema")
    if value["collector"] != "best-of-hands-local.v1":
        raise ValueError("unsupported evidence collector")
    if not isinstance(value["collected_at_utc"], str) or not re.fullmatch(
        r"20[0-9]{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01])T"
        r"(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](?:\.[0-9]{1,6})?\+00:00",
        value["collected_at_utc"],
    ):
        raise ValueError("invalid collection timestamp")
    build = value["steam_build_id"]
    if build is not None and (not isinstance(build, str) or not BUILD_ID.fullmatch(build)):
        raise ValueError("evidence Steam build ID is invalid")
    if expected_build and build != expected_build:
        raise ValueError("evidence Steam build ID does not match the workflow input")
    executable = value["executable"]
    if not isinstance(executable, dict) or set(executable) != {
        "name", "file_size", "sha256", "pe_timestamp", "size_of_image", "file_version"
    }:
        raise ValueError("invalid executable evidence fields")
    if executable["name"] not in {"bg3.exe", "bg3_dx11.exe"}:
        raise ValueError("unexpected executable name")
    if expected_executable and executable["name"] != expected_executable:
        raise ValueError("evidence executable does not match the workflow input")
    for field in ("file_size", "pe_timestamp", "size_of_image"):
        if type(executable[field]) is not int or executable[field] < 0:
            raise ValueError(f"invalid executable {field}")
    if executable["file_size"] == 0 or executable["size_of_image"] == 0:
        raise ValueError("executable sizes must be positive")
    if not re.fullmatch(r"[0-9a-f]{64}", str(executable["sha256"])):
        raise ValueError("invalid executable SHA-256")
    if not isinstance(executable["file_version"], str) or not re.fullmatch(
        r"(?:[0-9]{1,10}\.){3}[0-9]{1,10}|unavailable", executable["file_version"]
    ):
        raise ValueError("invalid executable file version")

    sections = value["sections"]
    if not isinstance(sections, list) or not 1 <= len(sections) <= 32:
        raise ValueError("invalid evidence sections")
    section_fields = {
        "name", "rva", "virtual_size", "raw_size", "sha256", "executable", "writable"
    }
    for section in sections:
        if not isinstance(section, dict) or set(section) != section_fields:
            raise ValueError("invalid section evidence fields")
        if not isinstance(section["name"], str) or not re.fullmatch(r"[.A-Za-z0-9_$]{1,16}", section["name"]):
            raise ValueError("invalid section name")
        for field in ("rva", "virtual_size", "raw_size"):
            if type(section[field]) is not int or section[field] < 0:
                raise ValueError(f"invalid section {field}")
        if not re.fullmatch(r"[0-9a-f]{64}", str(section["sha256"])):
            raise ValueError("invalid section SHA-256")
        if type(section["executable"]) is not bool or type(section["writable"]) is not bool:
            raise ValueError("invalid section flags")

    expected_anchors = {
        "client_task_selection", "client_input_controller_update",
        "client_get_character_task", "client_set_running_task", "profile_ui",
        "profile_math", "client_roll_start", "client_roll_result",
    }
    anchors = value["anchors"]
    if not isinstance(anchors, dict) or set(anchors) != expected_anchors:
        raise ValueError("invalid anchor set")
    for name, anchor in anchors.items():
        expected_fields = {"candidate_count", "candidates"}
        if name == "client_set_running_task":
            expected_fields |= {"relationship", "delta_rva"}
        if not isinstance(anchor, dict) or set(anchor) != expected_fields:
            raise ValueError("invalid anchor evidence fields")
        candidates = anchor["candidates"]
        if not isinstance(candidates, list) or len(candidates) > 16:
            raise ValueError("invalid anchor candidates")
        if type(anchor["candidate_count"]) is not int or anchor["candidate_count"] != len(candidates):
            raise ValueError("anchor candidate count mismatch")
        if name == "client_set_running_task" and (
            anchor["relationship"] != "client_get_character_task_plus_delta"
            or anchor["delta_rva"] != 0x20
        ):
            raise ValueError("invalid related task anchor")
        for candidate in candidates:
            if not isinstance(candidate, dict) or set(candidate) != {
                "rva", "instruction_count", "normalized_sha256", "control_flow"
            }:
                raise ValueError("invalid anchor candidate fields")
            if type(candidate["rva"]) is not int or not 0 <= candidate["rva"] < executable["size_of_image"]:
                raise ValueError("candidate RVA outside image")
            if type(candidate["instruction_count"]) is not int or not 1 <= candidate["instruction_count"] <= 16:
                raise ValueError("invalid instruction count")
            if not re.fullmatch(r"[0-9a-f]{64}", str(candidate["normalized_sha256"])):
                raise ValueError("invalid normalized fingerprint")
            edges = candidate["control_flow"]
            if not isinstance(edges, list) or len(edges) > 16 or any(
                not isinstance(edge, str)
                or not re.fullmatch(r"[a-z][a-z0-9_.]{0,15}:(?:forward|back)", edge)
                for edge in edges
            ):
                raise ValueError("invalid control-flow evidence")

    validation = value["validation"]
    if not isinstance(validation, dict) or set(validation) != {
        "pe_amd64", "candidate_rvas_within_image",
        "contains_executable_bytes", "contains_absolute_paths",
    }:
        raise ValueError("invalid evidence validation fields")
    if validation != {
        "pe_amd64": True, "candidate_rvas_within_image": True,
        "contains_executable_bytes": False, "contains_absolute_paths": False,
    }:
        raise ValueError("evidence self-validation failed")
    encoded = json.dumps(value, separators=(",", ":"))
    if len(encoded) > 250_000:
        raise ValueError("evidence exceeds 250 KB")
    return value


def validate_patch(encoded: str) -> bytes:
    try:
        patch = base64.b64decode(encoded, validate=True)
    except Exception as error:
        raise ValueError("patch is not strict base64") from error
    if not patch or len(patch) > 250_000 or b"\0" in patch:
        raise ValueError("patch is empty, binary, or exceeds 250 KB")
    text = patch.decode("utf-8")
    forbidden_extensions = (".exe", ".dll", ".pak", ".zip", ".7z", ".bin")
    allowed_prefixes = ("native/", "src/BestOfHands/", "tests/")
    allowed_files = {"README.md", "DEVELOPMENT.md"}
    blocks = re.split(r"(?m)(?=^diff --git )", text)
    blocks = [block for block in blocks if block]
    if not blocks or not all(block.startswith("diff --git ") for block in blocks):
        raise ValueError("patch contains no modified files")
    paths: list[str] = []
    for block in blocks:
        header = block.splitlines()[0]
        parts = shlex.split(header)
        if len(parts) != 4 or parts[:2] != ["diff", "--git"]:
            raise ValueError("malformed diff header")
        old, new = parts[2], parts[3]
        if not old.startswith("a/") or not new.startswith("b/") or old[2:] != new[2:]:
            raise ValueError("renames and copies are forbidden")
        path = new[2:]
        paths.append(path)
        for prefix in ("--- ", "+++ "):
            lines = [line for line in block.splitlines() if line.startswith(prefix)]
            if len(lines) != 1:
                raise ValueError("patch block has malformed file headers")
            value = lines[0][len(prefix):]
            if value != "/dev/null" and value not in {"a/" + path, "b/" + path}:
                raise ValueError("patch file headers disagree")
        if ".." in Path(path).parts or path.startswith(("/", "\\")):
            raise ValueError("patch contains path traversal")
        if path not in allowed_files and not path.startswith(allowed_prefixes):
            raise ValueError(f"patch modifies forbidden path: {path}")
        if path.lower().endswith(forbidden_extensions):
            raise ValueError(f"patch modifies forbidden binary path: {path}")
    if re.search(r"(?m)^(?:old mode|new mode) [0-9]{6}$", text) \
        or re.search(r"(?m)^(?:new file mode|deleted file mode) (?!100644$)[0-9]{6}$", text) \
        or re.search(r"(?m)^(?:rename|copy) (?:from|to) ", text) \
        or "GIT binary patch" in text or "Binary files " in text:
        raise ValueError("binary, symlink, and submodule patches are forbidden")
    return patch
