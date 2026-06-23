#!/usr/bin/env python3
## py-bom-weather.py
"""
Parse BOM XML (IDV60920.xml), keep a rolling history of MSL pressure
values per WMO station, and render a text view grouped by config.
"""
from __future__ import annotations

import argparse
import logging
import re
import xml.etree.ElementTree as ET
from collections import deque, OrderedDict
from dataclasses import dataclass
from pathlib import Path
from typing import Deque, Dict, Iterable, List, Mapping, Optional, Tuple

# Defaults
CACHE_DIR = Path.home() / "bin" / "bom" / "py
CONFIG_PATH = Path.home() / ".config" / "bom_weather" / "bom_weather.config"

XML_PATH = CACHE_DIR / "IDV60920.xml"
OUT_PATH = CACHE_DIR / "pressure_history.txt"

DEFAULT_HISTORY_SIZE = 10

log = logging.getLogger(__name__)


@dataclass
class Station:
    wmo: str
    name: str
    mslp: str


@dataclass
class HistoryEntry:
    name: str
    values: Deque[str]


# ----------------------------
# CONFIG
# ----------------------------
def load_config(path: Path) -> "OrderedDict[str, List[Tuple[str, str]]]":
    """
    Load config file mapping state -> list of (district_id, district_name).

    Expected lines:
      ## State Name
      [STATE_DISTRICT_ID]="District Name"

    Returns an OrderedDict preserving the order states appear in the file.
    Missing file returns an empty OrderedDict.
    """
    state_order: "OrderedDict[str, List[Tuple[str, str]]]" = OrderedDict()
    pattern = re.compile(r'\[([^]]+)\]\s*=\s*"([^"]+)"')

    if not path.exists():
        log.warning("Config file %s not found; proceeding with empty config.", path)
        return state_order

    current_state: Optional[str] = None
    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue

            if line.startswith("##"):
                current_state = line.strip("# ").strip()
                state_order.setdefault(current_state, [])
                continue

            m = pattern.search(line)
            if m:
                district_id, district_name = m.groups()
                state = district_id.split("_", 1)[0]
                # ensure top-level state entry exists (use the explicit `##` state when present)
                state_order.setdefault(state, [])
                state_order[state].append((district_id, district_name))

    return state_order


# ----------------------------
# XML PARSE (FIXED GROUPING)
# ----------------------------
def load_xml(path: Path) -> Dict[str, List[Station]]:
    """
    Parse the BOM XML and return mapping district_id -> list of Station
    """
    if not path.exists():
        raise FileNotFoundError(f"XML file not found: {path}")

    try:
        tree = ET.parse(str(path))
    except ET.ParseError as exc:
        raise RuntimeError(f"Failed to parse XML {path}: {exc}") from exc

    root = tree.getroot()
    stations_by_district: Dict[str, List[Station]] = {}

    for stn in root.findall(".//station"):
        wmo = stn.get("wmo-id")
        name = stn.get("description") or "UNKNOWN"
        district = stn.get("forecast-district-id")

        # find MSL pressure 
        mslp = stn.find(".//level[@type='surface']/element[@type='msl_pres']")
        mslp_val = mslp.text.strip() if (mslp is not None and mslp.text) else "-"

        if not wmo or not district:
            # skip malformed station entries
            continue

        stations_by_district.setdefault(district, []).append(
            Station(wmo, name, mslp_val)
        )

    return stations_by_district


# ----------------------------
# HISTORY LOAD
# ----------------------------
def load_history(path: Path, history_size: int = DEFAULT_HISTORY_SIZE) -> Dict[str, HistoryEntry]:
    """
    Load existing history file into memory.

    Format per-line:
      WMO|Station Name|val1,val2,val3

    Lines starting with '#' or without '|' are ignored.
    """
    history: Dict[str, HistoryEntry] = {}

    if not path.exists():
        return history

    with path.open("r", encoding="utf-8") as fh:
        for raw in fh:
            line = raw.rstrip("\n")
            if not line or line.startswith("#") or "|" not in line:
                continue

            parts = [p.strip() for p in line.split("|", 2)]
            if len(parts) < 3:
                continue
            wmo, name, values = parts
            dq = deque((v for v in (values.split(",") if values else []) if v), maxlen=history_size)
            history[wmo] = HistoryEntry(name=name, values=dq)

    return history


# ----------------------------
# UPDATE HISTORY
# ----------------------------
def update_history(history: Dict[str, HistoryEntry], stations_by_district: Mapping[str, Iterable[Station]], history_size: int = DEFAULT_HISTORY_SIZE) -> Dict[str, HistoryEntry]:
    """
    Append latest MSLP values (strings) to history deques for each station seen
    in the XML. Creates history entries for new WMOs.
    """
    for stations in stations_by_district.values():
        for s in stations:
            wmo = s.wmo
            name = s.name
            value = s.mslp

            if wmo not in history:
                history[wmo] = HistoryEntry(name=name, values=deque(maxlen=history_size))

            # always update stored name (in case it changed)
            history[wmo].name = name
            history[wmo].values.append(value)

    return history


# ----------------------------
# SAVE HISTORY
# ----------------------------
def save_history(path: Path, history: Mapping[str, HistoryEntry]) -> None:
    """
    Persist the history mapping to `path`. Each line is: WMO|Name|val1,val2,...
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    lines: List[str] = []
    for wmo, entry in history.items():
        values = ",".join(entry.values)
        lines.append(f"{wmo}|{entry.name}|{values}")

    path.write_text("\n".join(lines), encoding="utf-8")


# ----------------------------
# RENDER
# ----------------------------
def render(config: Mapping[str, Iterable[Tuple[str, str]]], history: Mapping[str, HistoryEntry], stations_by_district: Mapping[str, Iterable[Station]]) -> str:
    """
    Render the textual view grouping stations by the config order.
    """
    out_lines: List[str] = []
    for state, districts in config.items():
        out_lines.append(f"### {state} ###")
        for district_id, district_name in districts:
            out_lines.append(f"   {district_id} - {district_name}")
            stations = stations_by_district.get(district_id, [])
            for s in stations:
                wmo = s.wmo
                if wmo not in history:
                    continue
                h = history[wmo]
                values = ",".join(h.values)
                out_lines.append(f"      {wmo} | {h.name} | {values}")
        out_lines.append("")

    return "\n".join(out_lines)


# ----------------------------
# MAIN
# ----------------------------
def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description="Maintain MSLP history from BOM XML and render per-config view.")
    parser.add_argument("--xml", type=Path, default=XML_PATH, help="Path to the BOM XML file")
    parser.add_argument("--config", type=Path, default=CONFIG_PATH, help="Path to the config file")
    parser.add_argument("--out", type=Path, default=OUT_PATH, help="Path to the history output file")
    parser.add_argument("--history-size", type=int, default=DEFAULT_HISTORY_SIZE, help="Number of history values to keep per station")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")

    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO, format="%(levelname)s: %(message)s")

    if not args.xml.exists():
        log.error("Missing XML file at %s. Run py_fetch_xml.sh first.", args.xml)
        return 2

    # ensure cache dir exists
    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    config = load_config(args.config)
    stations_by_district = load_xml(args.xml)

    history = load_history(args.out, history_size=args.history_size)
    history = update_history(history, stations_by_district, history_size=args.history_size)

    save_history(args.out, history)

    output = render(config, history, stations_by_district)
    print(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
