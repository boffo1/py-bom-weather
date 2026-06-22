#!/usr/bin/env python3
## py-bom-weather.py
import re
import xml.etree.ElementTree as ET
from collections import deque, OrderedDict
from pathlib import Path

CACHE_DIR = Path.home() / ".cache" / "bom_weather"
CONFIG_PATH = Path.home() / ".config" / "bom_weather" / "bom_weather.config"

XML_PATH = CACHE_DIR / "IDV60920.xml"
OUT_PATH = CACHE_DIR / "pressure_history.txt"

HISTORY_SIZE = 10


# ----------------------------
# CONFIG
# ----------------------------
def load_config(path):
    state_order = OrderedDict()
    pattern = re.compile(r"\[(.+?)\]=\"(.+?)\"")

    current_state = None

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()

            if line.startswith("##"):
                current_state = line.strip("# ").strip()
                state_order.setdefault(current_state, [])

            match = pattern.search(line)
            if match:
                district_id, district_name = match.groups()
                state = district_id.split("_")[0]

                state_order.setdefault(state, [])
                state_order[state].append((district_id, district_name))

    return state_order


# ----------------------------
# XML PARSE (FIXED GROUPING)
# ----------------------------
def load_xml(path):
    tree = ET.parse(path)
    root = tree.getroot()

    stations_by_district = {}

    for stn in root.findall(".//station"):
        wmo = stn.get("wmo-id")
        name = stn.get("stn-name")
        district = stn.get("forecast-district-id")

        mslp = stn.find(".//level[@type='surface']/element[@type='msl_pres']")
        mslp_val = mslp.text.strip() if (mslp is not None and mslp.text) else "-"

        if not wmo or not district:
            continue

        stations_by_district.setdefault(district, []).append({
            "wmo": wmo,
            "name": name or "UNKNOWN",
            "mslp": mslp_val
        })

    return stations_by_district


# ----------------------------
# HISTORY LOAD
# ----------------------------
def load_history(path):
    history = {}

    if not path.exists():
        return history

    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            if "|" not in line or line.startswith("#"):
                continue

            wmo, name, values = [p.strip() for p in line.split("|", 2)]
            dq = deque([v for v in values.split(",") if v], maxlen=HISTORY_SIZE)

            history[wmo] = {"name": name, "values": dq}

    return history


# ----------------------------
# UPDATE HISTORY
# ----------------------------
def update_history(history, stations_by_district):
    for stations in stations_by_district.values():
        for s in stations:
            wmo = s["wmo"]
            name = s["name"]
            value = s["mslp"]

            if wmo not in history:
                history[wmo] = {
                    "name": name,
                    "values": deque(maxlen=HISTORY_SIZE)
                }

            history[wmo]["name"] = name
            history[wmo]["values"].append(value)

    return history


# ----------------------------
# SAVE HISTORY
# ----------------------------
def save_history(path, history):
    lines = []

    for wmo, data in history.items():
        values = ",".join(list(data["values"]))
        lines.append(f"{wmo}|{data['name']}|{values}")

    path.write_text("\n".join(lines), encoding="utf-8")


# ----------------------------
# RENDER
# ----------------------------
def render(config, history, stations_by_district):
    lines = []

    for state, districts in config.items():
        lines.append(f"### {state} ###")

        for district_id, district_name in districts:
            lines.append(f"   {district_id} - {district_name}")

            stations = stations_by_district.get(district_id, [])

            for s in stations:
                wmo = s["wmo"]

                if wmo not in history:
                    continue

                h = history[wmo]
                values = ",".join(h["values"])

                lines.append(f"      {wmo} | {h['name']} | {values}")

        lines.append("")

    return "\n".join(lines)


# ----------------------------
# MAIN
# ----------------------------
def main():
    if not XML_PATH.exists():
        raise FileNotFoundError("Missing XML. Run py_fetch_xml.sh first.")

    CACHE_DIR.mkdir(parents=True, exist_ok=True)

    config = load_config(CONFIG_PATH)
    stations_by_district = load_xml(XML_PATH)

    history = load_history(OUT_PATH)
    history = update_history(history, stations_by_district)

    save_history(OUT_PATH, history)

    output = render(config, history, stations_by_district)
    print(output)


if __name__ == "__main__":
    main()
