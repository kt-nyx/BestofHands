# SPDX-License-Identifier: Unlicense
"""Create sanitized BG3 compatibility evidence without emitting executable bytes."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path

import pefile
from capstone import Cs, CS_ARCH_X86, CS_MODE_64
from capstone.x86 import X86_OP_IMM, X86_OP_MEM, X86_REG_RIP


ANCHORS = {
    "client_task_selection": "488b46308b4e3c488d0cc8483bc1741e",
    "client_input_controller_update": "40534883ec30488bd9488b4930",
    "client_get_character_task": "83faff740c488b41304863d2488b04d0",
    "profile_ui": "4c897d10498b17498b0c24",
    "profile_math": "4d8b40204c894588498b4560",
    "client_roll_start": "488bc4555657488d68a14881eca0000000",
    "client_roll_result": "84c97406807b43007514807b420074",
}
CLIENT_SET_RUNNING_TASK = bytes.fromhex(
    "48895c2408488974241848897c2420554154415541564157"
)
TASK_HELPER_DELTA_RVA = 0x20


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def normalized_fingerprint(code: bytes, address: int) -> dict[str, object]:
    decoder = Cs(CS_ARCH_X86, CS_MODE_64)
    decoder.detail = True
    tokens: list[str] = []
    edges: list[str] = []
    for instruction in list(decoder.disasm(code, address, count=16)):
        operands: list[str] = []
        for operand in instruction.operands:
            if operand.type == X86_OP_IMM:
                if instruction.group(1) or instruction.group(2):
                    direction = "back" if operand.imm < instruction.address else "forward"
                    operands.append("edge:" + direction)
                    edges.append(instruction.mnemonic + ":" + direction)
                else:
                    operands.append("imm")
            elif operand.type == X86_OP_MEM:
                displacement = "rip" if operand.mem.base == X86_REG_RIP else str(operand.mem.disp)
                operands.append(
                    f"mem:{operand.size}:{operand.mem.base}:{operand.mem.index}:"
                    f"{operand.mem.scale}:{displacement}"
                )
            else:
                operands.append(f"{operand.type}:{operand.size}:{getattr(operand, 'reg', 0)}")
        tokens.append(f"{instruction.mnemonic}|{'|'.join(operands)}")
    normalized = "\n".join(tokens).encode("utf-8")
    return {
        "instruction_count": len(tokens),
        "normalized_sha256": sha256(normalized),
        "control_flow": edges,
    }


def collect(executable: Path, steam_build_id: str | None) -> dict[str, object]:
    data = executable.read_bytes()
    pe = pefile.PE(data=data, fast_load=False)
    sections = []
    executable_ranges: list[tuple[int, bytes]] = []
    for section in pe.sections:
        name = section.Name.rstrip(b"\0").decode("ascii", errors="replace")
        payload = section.get_data()
        rva = int(section.VirtualAddress)
        characteristics = int(section.Characteristics)
        sections.append({
            "name": name,
            "rva": rva,
            "virtual_size": int(section.Misc_VirtualSize),
            "raw_size": len(payload),
            "sha256": sha256(payload),
            "executable": bool(characteristics & 0x20000000),
            "writable": bool(characteristics & 0x80000000),
        })
        if characteristics & 0x20000000:
            executable_ranges.append((rva, payload))

    anchors: dict[str, object] = {}
    for name, encoded in ANCHORS.items():
        signature = bytes.fromhex(encoded)
        matches: list[dict[str, object]] = []
        for section_rva, payload in executable_ranges:
            offset = payload.find(signature)
            while offset >= 0:
                rva = section_rva + offset
                sample = payload[offset : offset + 128]
                matches.append({"rva": rva, **normalized_fingerprint(sample, rva)})
                offset = payload.find(signature, offset + 1)
        anchors[name] = {"candidate_count": len(matches), "candidates": matches}

    related_matches: list[dict[str, object]] = []
    get_task = anchors["client_get_character_task"]["candidates"]
    if len(get_task) == 1:
        related_rva = int(get_task[0]["rva"]) + TASK_HELPER_DELTA_RVA
        for section_rva, payload in executable_ranges:
            offset = related_rva - section_rva
            if 0 <= offset <= len(payload) - len(CLIENT_SET_RUNNING_TASK):
                if payload[offset : offset + len(CLIENT_SET_RUNNING_TASK)] == CLIENT_SET_RUNNING_TASK:
                    sample = payload[offset : offset + 128]
                    related_matches.append({
                        "rva": related_rva,
                        **normalized_fingerprint(sample, related_rva),
                    })
                break
    anchors["client_set_running_task"] = {
        "candidate_count": len(related_matches),
        "candidates": related_matches,
        "relationship": "client_get_character_task_plus_delta",
        "delta_rva": TASK_HELPER_DELTA_RVA,
    }

    version = "unavailable"
    if getattr(pe, "VS_FIXEDFILEINFO", None):
        info = pe.VS_FIXEDFILEINFO[0]
        version = ".".join(str(value) for value in (
            info.FileVersionMS >> 16, info.FileVersionMS & 0xFFFF,
            info.FileVersionLS >> 16, info.FileVersionLS & 0xFFFF,
        ))
    result: dict[str, object] = {
        "schema": "best-of-hands-compatibility-evidence.v1",
        "collector": "best-of-hands-local.v1",
        "collected_at_utc": datetime.now(timezone.utc).isoformat(),
        "steam_build_id": steam_build_id,
        "executable": {
            "name": executable.name,
            "file_size": len(data),
            "sha256": sha256(data),
            "pe_timestamp": int(pe.FILE_HEADER.TimeDateStamp),
            "size_of_image": int(pe.OPTIONAL_HEADER.SizeOfImage),
            "file_version": version,
        },
        "sections": sections,
        "anchors": anchors,
        "validation": {
            "pe_amd64": int(pe.FILE_HEADER.Machine) == 0x8664,
            "candidate_rvas_within_image": all(
                candidate["rva"] < int(pe.OPTIONAL_HEADER.SizeOfImage)
                for anchor in anchors.values()
                for candidate in anchor["candidates"]
            ),
            "contains_executable_bytes": False,
            "contains_absolute_paths": False,
        },
    }
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--steam-build-id")
    args = parser.parse_args()
    if args.steam_build_id and not re.fullmatch(r"[1-9][0-9]*", args.steam_build_id):
        parser.error("--steam-build-id must be a positive decimal build ID")
    resolved = args.executable.resolve(strict=True)
    if resolved.name.lower() not in {"bg3.exe", "bg3_dx11.exe"}:
        parser.error("executable must be bg3.exe or bg3_dx11.exe")
    evidence = collect(resolved, args.steam_build_id)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote sanitized evidence to {args.output}")


if __name__ == "__main__":
    main()
