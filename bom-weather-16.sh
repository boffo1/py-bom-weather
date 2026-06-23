#!/usr/bin/env bash
## bom-weather.sh - Comprehensive BoM XML parser via xmlstarlet from "ftp://ftp.bom.gov.au/anon/gen/fwo/"
## Usage:
##    bom-weather.sh                                   # Defaults to VIC, --district VIC_PW007 (central)
##    bom-weather.sh --district [<district_id>]        # Colorized district summary (hPa)
##    bom-weather.sh --district [<district_id>] --inhg # Summary with Pressure in inches of Mercury
##    bom-weather.sh --inhg, --inch-hg                 # Default district, Pressure unit inch Mercury(Hg)
##    bom-weather.sh --list, --ls                      # List available stations
##    bom-weather.sh --list-district, --ld             # List available district codes and names
##    bom-weather.sh --no-download, --nd               # Suppress download of remote file, use local file regardless of time stamp
##    bom-weather.sh --state <state>                   # Set state context (VIC, NSW, QLD, SA, WA, TAS, NT)
##    bom-weather.sh -v -n -q -s -w -t                 # Same as --state <state>, -d=NT
##    bom-weather.sh --vic --nsw --qld --sa --wa --tas --nt  # Same as --state <state> 
##    bom-weather.sh --station, --st <station>         # Single station mode.

## --- Global Defaults ---
state="VIC"
station_prefix=""
target_district=""
unit_mode=""
no_download="true" # default: do NOT download

## --- State to XML Prefix Map ---
declare -A STATE_PREFIX=(
  [VIC]=V
  [NSW]=N
  [QLD]=Q
  [SA]=S
  [WA]=W
  [TAS]=T
  [NT]=D
)

## --- Robust Consolidated Argument Parser ---
args=("$@")
idx=0

while [ $idx -lt ${#args[@]} ]; do
  token="${args[$idx]}"

  case "$token" in
    --list|--ls)
      action="list_stations"
      ;;

    --list-district|--ld)
      action="list_districts"
      ;;

    --district|--d)
      next="${args[$((idx+1))]:-}"
      if [[ -n "$next" && "$next" != --* ]]; then
        target_district="$next"
        idx=$((idx+1))
      else
        echo "Error: --district requires a district ID argument." >&2
        exit 1
      fi
      ;;

    --inhg|--inch-hg)
      unit_mode="--inhg"
      ;;

    --download|-d)
      no_download=false
      ;;

    --no-download|--nd)
      no_download=true
      ;;

    --station|--st)
      next="${args[$((idx+1))]:-}"
      if [[ -n "$next" && "$next" != --* ]]; then
        station_prefix="$next"
        action="single_station"
        idx=$((idx+1))
      else
        echo "Error: --station requires a prefix argument." >&2
        exit 1
      fi
      ;;

    --state)
      next="${args[$((idx+1))]:-}"
      if [[ -n "$next" && "$next" != --* ]]; then
        state="${next^^}"
        idx=$((idx+1))
      else
        echo "Error: --state requires a state name argument (e.g., VIC, NSW)." >&2
        exit 1
      fi
      ;;

    --vic|-v) state="VIC" ;;
    --nsw|-n) state="NSW" ;;
    --qld|-q) state="QLD" ;;
    --sa|-s)  state="SA"  ;;
    --wa|-w)  state="WA"  ;;
    --tas|-t) state="TAS" ;;
    --nt)     state="NT"  ;;

    [A-Z][A-Z][A-Z]_PW[0-9][0-9][0-9])
      target_district="$token"
      ;;

    *)
      echo "Unknown option or flag ignored: $token" >&2
      ;;
  esac

  idx=$((idx+1))
done

## --- Dynamic Local Storage & Config Paths ---
prefix="${STATE_PREFIX[$state]:-}"
if [ -z "$prefix" ]; then
  echo "Error: Unsupported or invalid state '$state'." >&2
  exit 1
fi

config_dir="$HOME/.config/bom_weather"
config_file="$config_dir/bom_weather.config"
filename="ID${prefix}60920.xml"
cache_dir="$HOME/.cache/bom_weather"
local_xml="$cache_dir/$filename"
ftp_url="ftp://ftp.bom.gov.au/anon/gen/fwo/$filename"
history_file="$cache_dir/pressure_history.txt"

## Ensure .cache and .config directories exist
mkdir -p "$cache_dir"
mkdir -p "$config_dir"
touch "$history_file"

## --- Load or Initialize External Configuration, VIC default---
if [ -f "$config_file" ]; then
    source "$config_file"
else
    echo "Notice: Configuration file missing. Generating default at $config_file"
    cat << 'EOF' > "$config_file"
# ~/.config/bom_weather/weather.config
declare -A DISTRICT_NAMES=(
    [VIC_PW001]="Mallee"
    [VIC_PW002]="Wimmera"
    [VIC_PW003]="Northern Country"
    [VIC_PW004]="North East"
    [VIC_PW005]="East Gippsland"
    [VIC_PW006]="West & South Gippsland"
    [VIC_PW007]="Central"
    [VIC_PW008]="North Central"
    [VIC_PW009]="South West"
    [VIC_MW001]="Portland Harbour"
    [VIC_MW005]="Port Phillip Bay"
    [VIC_FA001]="(Non-BoM) CFA & Portable stations"
  )
EOF
    source "$config_file"
fi

## Dynamic fallback default to capital city district if none was explicitly set during flag parsing
if [ -z "$target_district" ]; then
  case "$state" in
    VIC) target_district="VIC_PW007" ;; # Central (Melbourne)
    NSW) target_district="NSW_PW005" ;; # Sydney Metropolitan
    QLD) target_district="QLD_PW015" ;; # Brisbane/Southeast Coast
    SA)  target_district="SA_PW001"  ;; # Adelaide/Mount Lofty Ranges
    WA)  target_district="WA_PW009"  ;; # Perth/Lower West
    TAS) target_district="TAS_PW006" ;; # Hobart/Southeast
    NT)  target_district="NT_PW001"  ;; # Darwin/Tiwi
  esac
fi

## Helper: Conditional FTP Download xml data file only if newer than local xml file
fetch_xml_data() {
  if [ "$no_download" = true ]; then
    if [ ! -f "$local_xml" ]; then
      echo "Error: --no-download flag specified, but local file $local_xml is missing!" >&2
      exit 1
    fi
    echo "Notice: Operating in offline mode (--no-download). Using local file data." >&2
    echo ""
    return
  fi

  if [ -f "$local_xml" ]; then
    if stat -f %m "$local_xml" >/dev/null 2>&1; then
      mod_before=$(stat -f %m "$local_xml")
    else
      mod_before=$(stat -c %Y "$local_xml" 2>/dev/null || date -r "$local_xml" +%s 2>/dev/null)
    fi
      
    if ! curl -# -f -z "$local_xml" "$ftp_url" -o "$local_xml"; then 
      echo "Error: Failed to fetch updates from $ftp_url" >&2
      exit 1
    fi

    if stat -f %m "$local_xml" >/dev/null 2>&1; then
      mod_after=$(stat -f %m "$local_xml")
    else
      mod_after=$(stat -c %Y "$local_xml" 2>/dev/null || date -r "$local_xml" +%s 2>/dev/null)
    fi

    if [ "$mod_before" -eq "$mod_after" ]; then
      echo "Notice: Local file is up to date." >&2
      echo ""
    else
      echo "Notice: Remote file is newer. Updated data downloaded." >&2
      echo ""
    fi
  else
    echo "Notice: Local file missing. Downloading fresh copy..." >&2
    if ! curl -# -f "$ftp_url" -o "$local_xml"; then 
      echo "Error: Failed to fetch data from $ftp_url" >&2
      exit 1
    fi
  fi
}

## ANSI Colour Codes
RED='\033[91m'
GREEN='\033[32m'
BLUE='\033[94m'
YELLOW='\033[93m'
CYAN='\033[36m'
LCYAN='\033[96m'
BWHITE='\033[97m'
NC='\033[0m'

## Feature 1: List All Stations within a state, default VIC
list_stations() {
  fetch_xml_data
  echo -e "${CYAN}WMO ID     | BOM ID     | Station Name${NC}"
  echo "--------------------------------------------------------"
  # Build a safe key=value;key=value; string for awk
  district_map=""
  for key in "${!DISTRICT_NAMES[@]}"; do
      district_map+="${key}=${DISTRICT_NAMES[$key]};"
  done

  xmlstarlet select -t -m "//station" \
    -v "@forecast-district-id" -o "|" \
    -v "@wmo-id" -o "|" \
    -v "@bom-id" -o "|" \
    -v "@description" -n \
    "$local_xml" | \
  sort -t"|" -k1,1 | \

## Parse district map into array district_name[] and colourise ##
  awk -F "|" \
    -v dmap="$district_map" \
    -v LCYAN="$LCYAN" \
    -v NC="$NC" '
    BEGIN {
      n = split(dmap, arr, ";")
      for (i = 1; i <= n; i++) {
        split(arr[i], kv, "=")
      if (kv[1] != "")
          district_name[kv[1]] = kv[2]
    }
    }
    NR == 1 {
      prev = $1
      printf "\n%s=== %s — %s ===%s\n",
             LCYAN, $1, district_name[$1], NC
    }
    $1 != prev {
      print ""
      printf "%s=== %s — %s ===%s\n",
             LCYAN, $1, district_name[$1], NC
    }
    {
      wmo = ($2 == "" ? "   -----   " : $2)
      bom = ($3 == "" ? "   ------   " : $3)
      printf "%-10s | %-10s | %s\n", wmo, bom, $4
      prev = $1
    }'
  exit 0
}

## Feature 2: List Forecast Districts (Cleaned up via external config)
## syntax : bom-weather.sh --state <name> --list-district <iD> 
list_districts() {
  fetch_xml_data
  echo -e "${CYAN}District ID | Forecast Area Name${NC}"
  echo "----------------------------------------"
  xmlstarlet select -t -m "//station" -v "@forecast-district-id" -n "$local_xml" | \
    grep -v '^$' | sort -u | \
  while read -r dist_id; do
    area_name="${DISTRICT_NAMES[$dist_id]:-Other / Region Context}"
    printf "%-11s | %s\n" "$dist_id" "$area_name"
  done
  exit 0
}

## Feature 4 view a single station with in the state.
single_station_view() {
  local prefix="${station_prefix^^}"   # uppercase for matching
  fetch_xml_data

  echo -e "${CYAN}Single Station Mode — Prefix: ${prefix}${NC}"
  echo "——————————————————————————————————————————————————————————————————————————————"

  xmlstarlet select -t \
    -m "//station" \
    -v "@wmo-id" -o "|" \
    -v "@description" -o "|" \
    -v "(.//element[@type='air_temperature'])[1]" -o "|" \
    -v "(.//element[@type='dew_point'])[1]" -o "|" \
    -v "(.//element[@type='rel-humidity'])[1]" -o "|" \
    -v "(.//element[@type='msl_pres'])[1]" -n "$local_xml" | \
  while IFS="|" read -r wmo name raw_temp raw_dew raw_rhum raw_mslp; do

    # Match prefix (case‑insensitive)
    if [[ "${name^^}" != ${prefix}* ]]; then
      continue
    fi

    # Clean values
    temp=$(echo "$raw_temp" | tr -d '[:space:]')
    dew=$(echo "$raw_dew" | tr -d '[:space:]')
    rhum=$(echo "$raw_rhum" | tr -d '[:space:]')
    mslp=$(echo "$raw_mslp" | tr -d '[:space:]')

    echo -e "${YELLOW}${name}${NC}"
    echo "----------------------------------------"

    printf "Temperature:     %s°C\n" "${temp:-N/A}"
    printf "Dew Point:       %s°C\n" "${dew:-N/A}"
    printf "Humidity:        %s%%\n" "${rhum:-N/A}"

    # Default trend
    trend=""

    # Pressure + trend arrow
    if [[ -n "$mslp" && "$mslp" =~ ^[0-9.]+$ ]]; then
      history_row=$(grep "^${wmo}:" "$history_file" | head -n1 | cut -d':' -f2)
      mslp_prev=$(echo "$history_row" | cut -d',' -f1)

      if [[ -n "$mslp_prev" && "$mslp_prev" =~ ^[0-9.]+$ ]]; then
        if (( $(echo "$mslp > $mslp_prev" | bc -l) )); then
          trend=""
        elif (( $(echo "$mslp < $mslp_prev" | bc -l) )); then
          trend=""
        fi
      fi
    fi

    printf "MSL Pressure:    %s hPa   %s\n" "${mslp:-N/A}" "$trend"

    # Update history
    if [[ "$mslp" = "$mslp_prev" ]]; then
      updated_csv_row="$history_row"
    else
      if [[ -n "$history_row" ]]; then
        updated_csv_row=$(echo "${mslp},${history_row}" | cut -d',' -f1-9)
      else
        updated_csv_row="$mslp"
      fi
    fi

    echo "${name}:${updated_csv_row}" >> "${history_file}.tmp"
    echo "——————————————————————————————————————————————————————————————————————————————"
  done ## <-- ✔️ CLOSE THE WHILE LOOP
#  mv "${history_file}.tmp" "$history_file"
} ## <-- ✔️ NOW close the function

## --- Feature 3: Colorized District Summary Mode ---
view_district() {
  local target_district="$1"
  local unit_mode="$2"
   
  fetch_xml_data

  if [ "$unit_mode" = "--inhg" ]; then
    local pres_label="      inHg "
  else
    local pres_label="     hPa "
  fi

  local raw_time=$(xmlstarlet select -t -v "//amoc/issue-time-utc" "$local_xml" 2>/dev/null)
  local formatted_time="Unknown Time"
   
  if [ -n "$raw_time" ]; then
    if date -d "$raw_time" >/dev/null 2>&1; then
      formatted_time=$(date -d "$raw_time" +"%d/%m/%Y %I:%M %p Local")
    else
      formatted_time=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$raw_time" +"%d/%m/%Y %I:%M %p Local" 2>/dev/null || echo "$raw_time")
    fi
  fi

  printf "%s\n" "————————————————————————————————————————————————————————————————————————————————————————"
  printf "   ${CYAN}BoM Stations Data ($target_district) -|- %s${NC}\n" "$formatted_time"
  printf "%s\n" "————————————————————————————————————————————————————————————————————————————————————————"
  printf "%-29s | %-11s | %-9s | %-8s | %-15s\n" "      Station Name" "Temperature" "Dew Point" "Humidity" "MSL Pressure"
  printf "%s\n" "----------------------------------------------------------------------------------------"
  printf "%-29s | %-12s | %-10s | %-8s | %-15s\n" " " "    °C " "    °C " "  % " "$pres_label"
  printf "%s\n" "————————————————————————————————————————————————————————————————————————————————————————"

xmlstarlet select -t \
    -m "//station[@forecast-district-id='$target_district']" \
    -v "@description" -o "|" \
    -v "(.//element[@type='air_temperature'])[1]" -o "|" \
    -v "(.//element[@type='dew_point'])[1]" -o "|" \
    -v "(.//element[@type='rel-humidity'])[1]" -o "|" \
    -v "(.//element[@type='msl_pres'])[1]" -n "$local_xml" | \
  while IFS="|" read -r name raw_temp raw_dew raw_rhum raw_mslp; do
    ## Optional trim
    name=$(printf '%s\n' "$name" | xargs -0)
    temp=$(echo "$raw_temp" | tr -d '[:space:]')
    dew=$(echo "$raw_dew" | tr -d '[:space:]')
    rhum=$(echo "$raw_rhum" | tr -d '[:space:]')
    mslp=$(echo "$raw_mslp" | tr -d '[:space:]')

    [ -z "$name" ] && continue

    ## --- Smart Name Truncation ---
    if [ ${#name} -gt 27 ]; then
      name="${name:0:26}…"
    fi
    ## Colourise the fonts
    if [[ -z "$temp" || ! "$temp" =~ ^[0-9.-]+$ ]]; then
      printf -v pad_temp "%-13s" "    ⁻"
      color_temp="${pad_temp}"
    else
      printf -v pad_temp "%-11s" "   ${temp}"
      if (( $(echo "$temp >= 19.0" | bc -l) )); then
        color_temp="${RED}${pad_temp}${NC}"
      elif (( $(echo "$temp >= 15.0" | bc -l) )); then
        color_temp="${YELLOW}${pad_temp}${NC}"
      elif (( $(echo "$temp >= 10.1" | bc -l) )); then
        color_temp="${BLUE}${pad_temp}${NC}"
      elif (( $(echo "$temp >= 7.1" | bc -l) )); then
        color_temp="${CYAN}${pad_temp}${NC}"
      elif (( $(echo "$temp >= 4.1 " | bc -l) )); then
        color_temp="${LCYAN}${pad_temp}${NC}"
      else
        color_temp="${BWHITE}${pad_temp}${NC}"
      fi
    fi

    if [[ -z "$dew" || ! "$dew" =~ ^[0-9.-]+$ ]]; then
      printf -v color_dew "%-11s" "   ⁻"
    else
      printf -v color_dew "%-9s" "  ${dew}"
    fi

    if [[ -z "$rhum" || ! "$rhum" =~ ^[0-9.]+$ ]]; then
      printf -v color_rhum "%-10s" "   ⁻"
    else
      printf -v color_rhum "%-8s" "  ${rhum}"
    fi

    ## --- MSL Pressure convert to inch Hg (Mercury) ---
    if [[ -z "$mslp" || ! "$mslp" =~ ^[0-9.]+$ ]]; then
      printf -v color_mslp "%-16s" "      ⁻"
    else
      if [ "$unit_mode" = "--inhg" ]; then
        display_pres=$(awk -v h="$mslp" 'BEGIN{printf "%.2f", h * 0.0295299830714}')
      else
        display_pres="$mslp"
      fi

      ## Fetch historical comma-separated data line for the station
      history_row=$(grep "^${name}:" "$history_file" | head -n1 | cut -d':' -f2)
      ## Extract the immediate previous value (the first item before any comma)
      mslp_prev=$(echo "$history_row" | cut -d',' -f1)

      if [[ -n "$mslp_prev" && "$mslp_prev" =~ ^[0-9.]+$ ]]; then
        if (( $(echo "$mslp > $mslp_prev" | bc -l) )); then
          printf -v pad_mslp "%-15s" "   ${display_pres}  "
          color_mslp="${RED}${pad_mslp}${NC}" # Rising trend  U+E696
        elif (( $(echo "$mslp < $mslp_prev" | bc -l) )); then
          printf -v pad_mslp "%-15s" "   ${display_pres}  "
          color_mslp="${BLUE}${pad_mslp}${NC}" # Falling trend  U+E697
        else
          printf -v pad_mslp "%-15s" "   ${display_pres}  "
          color_mslp="${GREEN}${pad_mslp}${NC}" # Steady trend  U+E695
        fi
      else
        ## Fallback if no prior data point is found in the history file yet
        printf -v pad_mslp "%-15s" "   ${display_pres}  "
        color_mslp="${GREEN}${pad_mslp}${NC}"
      fi

      ## Dynamic rolling queue update logic: 
      ## If the new reading matches the most recent saved reading, keep the row completely unmodified.
      ## Otherwise, slice the new value onto the front and drop values beyond index 9.
      if [ "$mslp" = "$mslp_prev" ]; then
        updated_csv_row="$history_row"
      else
        if [ -n "$history_row" ]; then
          updated_csv_row=$(echo "${mslp},${history_row}" | cut -d',' -f1-9)
        else
          updated_csv_row="$mslp"
        fi
      fi

      ## Append fresh values to a temporary snapshot file
      echo "${name}:${updated_csv_row}" >> "${history_file}.tmp"
    fi
    printf "  %-27s | %b | %b | %b | %b\n" "$name" "$color_temp" "$color_dew" "$color_rhum" "$color_mslp"
  done

  ## Finalize history tracking without losing data elements belonging to alternate districts
  if [ -f "${history_file}.tmp" ]; then
    while IFS= read -r old_line; do
       old_stn=$(echo "$old_line" | cut -d':' -f1)
       if ! grep -F -q "^${old_stn}:" "${history_file}.tmp"; then
         echo "$old_line" >> "${history_file}.tmp"
       fi
    done < "$history_file" 2>/dev/null
#    mv "${history_file}.tmp" "$history_file"
  fi
  printf "————————————————————————————————————————————————————————————————————————————————————————\n\n"
}

## --- Execution Router ---
case "${action:-view}" in
  list_stations)  list_stations ;;
  list_districts) list_districts ;;
  single_station) single_station_view ;;
  *)              view_district "$target_district" "$unit_mode" ;;
esac
