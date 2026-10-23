#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rebuild the Russian Big Dig patch from a local game installation.

The script only reads the game and writes to build/. It never modifies the
game directory. Requires UnityPy 1.25.2.
"""

from __future__ import annotations

import argparse
import copy
import json
import struct
import sys
from pathlib import Path

try:
    import UnityPy
except ImportError:
    sys.exit("UnityPy is required: pip install UnityPy==1.25.2")

TABLES = [
    "Dialogue",
    "UI",
    "MapSites",
    "Artifacts",
    "ArtifactDescriptions",
    "Upgrades",
]

RU_BUNDLE = "localization-string-tables-russian(ru)_assets_all.bundle"
EN_BUNDLE = "localization-string-tables-english(en)_assets_all.bundle"
LOCALES_BUNDLE = "localization-locales_assets_all.bundle"

# Big Dig v1.0 catalog layout. The script refuses to patch a different layout.
CATALOG_RECORDS = [
    (13893, "strings", 2775, 107187),
    (10431, "locales", 3065, 9355),
]

# Big Dig v1.0 disabledLocales list: da, fr, pt-BR, ru, es, de.
LEVEL_OLD = (
    b"\x06\x00\x00\x00"
    b"\x02\x00\x00\x00da\x00\x00"
    b"\x02\x00\x00\x00fr\x00\x00"
    b"\x05\x00\x00\x00pt-BR\x00\x00\x00"
    b"\x02\x00\x00\x00ru\x00\x00"
    b"\x02\x00\x00\x00es\x00\x00"
    b"\x02\x00\x00\x00de\x00\x00"
)
LEVEL_NEW = LEVEL_OLD.replace(
    b"\x02\x00\x00\x00ru\x00\x00",
    b"\x02\x00\x00\x00xx\x00\x00",
)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def find_aa_root(game: Path) -> Path:
    game = game.resolve()
    candidates = [
        game / "BigDig_Data" / "StreamingAssets" / "aa",
        game / "StreamingAssets" / "aa",
        game,
    ]
    for candidate in candidates:
        if (candidate / "catalog.bin").is_file() and (candidate / "StandaloneWindows64").is_dir():
            return candidate
    fail(
        "catalog.bin and StandaloneWindows64 not found. "
        "Pass the game folder, BigDig_Data or StreamingAssets/aa."
    )


def load_translations(root: Path) -> dict[str, dict[int, str]]:
    result: dict[str, dict[int, str]] = {}
    for name in TABLES:
        path = root / f"{name}.json"
        if not path.is_file():
            fail(f"translation not found: {path}")

        rows = json.loads(path.read_text(encoding="utf-8-sig"))
        by_id: dict[int, str] = {}
        for row in rows:
            row_id = int(row["id"])
            if row_id in by_id:
                fail(f"duplicate id {row_id} in {path.name}")
            by_id[row_id] = str(row.get("ru", ""))
        result[name] = by_id
    return result


def load_en_tables(path: Path) -> dict[str, dict]:
    env = UnityPy.load(str(path))
    tables: dict[str, dict] = {}
    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        tree = obj.read_typetree()
        name = tree.get("m_Name") or ""
        if name.endswith("_en"):
            tables[name[:-3]] = tree

    missing = [name for name in TABLES if name not in tables]
    if missing:
        fail(f"English tables missing: {', '.join(missing)}")
    return tables


def build_strings(
    source: Path,
    output: Path,
    en_tables: dict[str, dict],
    translations: dict[str, dict[int, str]],
) -> dict[str, int]:
    env = UnityPy.load(str(source))
    report: dict[str, int] = {}
    found = 0

    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue

        tree = obj.read_typetree()
        name = tree.get("m_Name") or ""
        if not name.endswith("_ru"):
            continue

        base = name[:-3]
        if base not in en_tables:
            fail(f"no English source for {name}")

        en = en_tables[base]
        ru = translations[base]
        rows = []
        seen = set()
        missing = []

        for row in en.get("m_TableData") or []:
            row_id = row.get("m_Id")
            seen.add(row_id)
            if row_id not in ru:
                missing.append(row_id)
                value = ""
            else:
                value = ru[row_id]
            rows.append(
                {
                    "m_Id": row_id,
                    "m_Localized": value,
                    "m_Metadata": copy.deepcopy(row.get("m_Metadata") or {"m_Items": []}),
                }
            )

        for row in tree.get("m_TableData") or []:
            row_id = row.get("m_Id")
            if row_id not in seen:
                rows.append(
                    {
                        "m_Id": row_id,
                        "m_Localized": ru.get(row_id, ""),
                        "m_Metadata": copy.deepcopy(row.get("m_Metadata") or {"m_Items": []}),
                    }
                )
                seen.add(row_id)

        if missing:
            preview = ", ".join(str(item) for item in missing[:8])
            fail(f"{base}: missing translations for ids {preview}")

        tree["m_TableData"] = rows
        tree["m_Metadata"] = copy.deepcopy(en.get("m_Metadata") or {"m_Items": []})
        tree["references"] = copy.deepcopy(en.get("references") or {"version": 2, "RefIds": []})
        obj.save_typetree(tree)

        report[base] = len(rows)
        found += 1

    if found != len(TABLES):
        fail(f"expected {len(TABLES)} Russian tables, found {found}")

    data = env.file.save()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)

    # Readback: every English row must match its translation.
    env2 = UnityPy.load(str(output))
    checked: dict[str, int] = {}
    bad = 0
    for obj in env2.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        tree = obj.read_typetree()
        name = tree.get("m_Name") or ""
        if not name.endswith("_ru"):
            continue
        base = name[:-3]
        if base not in TABLES:
            continue
        entries = {row["m_Id"]: row["m_Localized"] for row in tree.get("m_TableData") or []}
        en_ids = [row.get("m_Id") for row in en_tables[base].get("m_TableData") or []]
        for row_id in en_ids:
            if entries.get(row_id) != translations[base].get(row_id):
                bad += 1
        checked[base] = len(entries)

    if bad:
        fail(f"readback mismatch: {bad}")
    if checked != report:
        fail(f"readback table mismatch: {checked} != {report}")

    return report


def build_locales(source: Path, output: Path) -> str:
    env = UnityPy.load(str(source))
    found = False

    for obj in env.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        tree = obj.read_typetree()
        if tree.get("m_Name") == "Russian (ru)":
            tree["m_LocaleName"] = "Русский"
            obj.save_typetree(tree)
            found = True
            break

    if not found:
        fail("Russian locale object not found")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(env.file.save())

    env2 = UnityPy.load(str(output))
    for obj in env2.objects:
        if obj.type.name != "MonoBehaviour":
            continue
        tree = obj.read_typetree()
        if tree.get("m_Name") == "Russian (ru)":
            return tree.get("m_LocaleName") or ""

    fail("Russian locale object not found after rebuild")


def build_catalog(source: Path, output: Path, strings_size: int, locales_size: int) -> None:
    data = bytearray(source.read_bytes())

    for record, label, clean_size, patched_size in CATALOG_RECORDS:
        old_size = struct.unpack_from("<I", data, record + 12)[0]
        if old_size not in (clean_size, patched_size):
            fail(
                f"unsupported catalog record {record}: size {old_size}, "
                f"expected {clean_size} or {patched_size}. "
                "The game version probably changed."
            )

        new_size = strings_size if label == "strings" else locales_size
        struct.pack_into("<I", data, record + 8, 0)
        struct.pack_into("<I", data, record + 12, new_size)
        print(f"catalog: {label} record {record}: {old_size} -> {new_size}, crc -> 0")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)


def build_levels(game_data: Path, output_data: Path) -> None:
    for index in range(13):
        source = game_data / f"level{index}"
        if not source.is_file():
            fail(f"level not found: {source}")

        data = source.read_bytes()
        old_count = data.count(LEVEL_OLD)
        new_count = data.count(LEVEL_NEW)

        if old_count == 1:
            data = data.replace(LEVEL_OLD, LEVEL_NEW)
        elif new_count == 1:
            pass
        else:
            fail(
                f"level{index}: unknown disabledLocales layout "
                f"(old={old_count}, new={new_count}). "
                "The game version probably changed."
            )

        output = output_data / f"level{index}"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)

    print("levels: 13 patched")


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent

    parser = argparse.ArgumentParser(description="Rebuild the Big Dig Russian patch.")
    parser.add_argument(
        "--game",
        required=True,
        help="Game folder, BigDig_Data or StreamingAssets/aa",
    )
    parser.add_argument(
        "--translations",
        default=str(repo_root / "translation" / "ru"),
        help="Folder with the six translation JSON files",
    )
    parser.add_argument(
        "--out",
        default=str(repo_root / "build"),
        help="Output folder (default: build/)",
    )
    args = parser.parse_args()

    aa_root = find_aa_root(Path(args.game))
    game_data = aa_root.parent.parent
    translations_root = Path(args.translations).resolve()
    output_root = Path(args.out).resolve()
    output_data = output_root / "BigDig_Data"
    output_aa = output_data / "StreamingAssets" / "aa"
    output_bundles = output_aa / "StandaloneWindows64"

    print(f"game: {aa_root}")
    print(f"translations: {translations_root}")
    print(f"output: {output_root}")

    translations = load_translations(translations_root)
    en_tables = load_en_tables(aa_root / "StandaloneWindows64" / EN_BUNDLE)

    strings_output = output_bundles / RU_BUNDLE
    report = build_strings(
        aa_root / "StandaloneWindows64" / RU_BUNDLE,
        strings_output,
        en_tables,
        translations,
    )
    print(f"strings: {strings_output.stat().st_size} bytes, tables: {report}")

    locales_output = output_bundles / LOCALES_BUNDLE
    locale_name = build_locales(
        aa_root / "StandaloneWindows64" / LOCALES_BUNDLE,
        locales_output,
    )
    print(f"locales: {locales_output.stat().st_size} bytes, name: {locale_name}")

    build_catalog(
        aa_root / "catalog.bin",
        output_aa / "catalog.bin",
        strings_output.stat().st_size,
        locales_output.stat().st_size,
    )
    build_levels(game_data, output_data)

    print()
    print("done")
    print(f"result: {output_data}")
    print("Next: copy build/BigDig_Data into files/BigDig_Data and regenerate SHA256SUMS.txt.")


if __name__ == "__main__":
    main()
