#!/bin/bash
# iDRAC Fan Controller - Unraid Plugin version
# Reads config from /boot/config/plugins/idrac-fan-controller/idrac-fan-controller.cfg

CFG_FILE="/boot/config/plugins/idrac-fan-controller/idrac-fan-controller.cfg"
LOG_DIR="/mnt/user/appdata/idrac-fan-controller"
PID_FILE="/var/run/idrac-fan-controller.pid"
LOG_FILE="$LOG_DIR/service.log"

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [ ! -f "$CFG_FILE" ]; then
  echo "ERROR: Config file not found at $CFG_FILE" >&2
  exit 1
fi
source "$CFG_FILE"

# Set defaults
IDRAC_HOST="${IDRAC_HOST:-local}"
IDRAC_USERNAME="${IDRAC_USERNAME:-root}"
IDRAC_PASSWORD="${IDRAC_PASSWORD:-calvin}"
FAN_CONTROL_MODE="${FAN_CONTROL_MODE:-stepped}"
FAN_SPEED="${FAN_SPEED:-5}"
CPU_TEMPERATURE_THRESHOLD="${CPU_TEMPERATURE_THRESHOLD:-70}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-365}"
STEPPED_MID_TEMP="${STEPPED_MID_TEMP:-45}"
STEPPED_MID_FAN_SPEED="${STEPPED_MID_FAN_SPEED:-12}"
STEPPED_HIGH_TEMP="${STEPPED_HIGH_TEMP:-55}"
STEPPED_HIGH_FAN_SPEED="${STEPPED_HIGH_FAN_SPEED:-20}"
INTERP_LOW_TEMP="${INTERP_LOW_TEMP:-35}"
INTERP_HIGH_TEMP="${INTERP_HIGH_TEMP:-55}"
INTERP_HIGH_FAN_SPEED="${INTERP_HIGH_FAN_SPEED:-30}"
DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE="${DISABLE_THIRD_PARTY_PCIE_CARD_DELL_DEFAULT_COOLING_RESPONSE:-false}"
KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT="${KEEP_THIRD_PARTY_PCIE_CARD_COOLING_RESPONSE_STATE_ON_EXIT:-false}"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
echo $$ > "$PID_FILE"

# ipmitool login string
if [[ "$IDRAC_HOST" == "local" ]]; then
  IDRAC_LOGIN_STRING="open"
else
  IDRAC_LOGIN_STRING="lanplus -H $IDRAC_HOST -U $IDRAC_USERNAME -P $IDRAC_PASSWORD"
fi

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
function convert_decimal_value_to_hexadecimal() {
  printf '0x%02x' $1
}

function convert_hexadecimal_value_to_decimal() {
  printf '%d' $1
}

function apply_Dell_default_fan_control_profile() {
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null 2>&1
  CURRENT_FAN_CONTROL_PROFILE="Dell default dynamic fan control profile"
}

function apply_user_fan_control_profile() {
  local TARGET_SPEED="${1:-$DECIMAL_FAN_SPEED}"
  local HEX_SPEED
  HEX_SPEED=$(convert_decimal_value_to_hexadecimal "$TARGET_SPEED")
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x00 > /dev/null 2>&1
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x02 0xff $HEX_SPEED > /dev/null 2>&1
  CURRENT_FAN_CONTROL_PROFILE="User static fan control profile ($TARGET_SPEED%)"
}

function apply_stepped_fan_curve() {
  local CPU_TEMP="$1"
  if [ "$CPU_TEMP" -ge "$CPU_TEMPERATURE_THRESHOLD" ]; then
    apply_Dell_default_fan_control_profile
  elif [ "$CPU_TEMP" -ge "$STEPPED_HIGH_TEMP" ]; then
    apply_user_fan_control_profile "$STEPPED_HIGH_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - High stage ($STEPPED_HIGH_FAN_SPEED% @ ${CPU_TEMP}C)"
  elif [ "$CPU_TEMP" -ge "$STEPPED_MID_TEMP" ]; then
    apply_user_fan_control_profile "$STEPPED_MID_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - Mid stage ($STEPPED_MID_FAN_SPEED% @ ${CPU_TEMP}C)"
  else
    apply_user_fan_control_profile "$DECIMAL_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Stepped fan curve - Low stage ($DECIMAL_FAN_SPEED% @ ${CPU_TEMP}C)"
  fi
}

function apply_interpolated_fan_curve() {
  local CPU_TEMP="$1"
  if [ "$CPU_TEMP" -ge "$CPU_TEMPERATURE_THRESHOLD" ]; then
    apply_Dell_default_fan_control_profile
  elif [ "$CPU_TEMP" -ge "$INTERP_LOW_TEMP" ]; then
    local RANGE_TEMP=$(( INTERP_HIGH_TEMP - INTERP_LOW_TEMP ))
    local RANGE_SPEED=$(( INTERP_HIGH_FAN_SPEED - DECIMAL_FAN_SPEED ))
    local OFFSET=$(( CPU_TEMP - INTERP_LOW_TEMP ))
    local INTERPOLATED_SPEED=$(( DECIMAL_FAN_SPEED + (RANGE_SPEED * OFFSET * 100 / RANGE_TEMP + 50) / 100 ))
    apply_user_fan_control_profile "$INTERPOLATED_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Interpolated fan curve ($INTERPOLATED_SPEED% @ ${CPU_TEMP}C)"
  else
    apply_user_fan_control_profile "$DECIMAL_FAN_SPEED"
    CURRENT_FAN_CONTROL_PROFILE="Interpolated fan curve - Min ($DECIMAL_FAN_SPEED% @ ${CPU_TEMP}C)"
  fi
}

function retrieve_temperatures() {
  local DATA
  DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type temperature 2>/dev/null | grep degrees)

  local CPU_DATA
  CPU_DATA=$(echo "$DATA" | grep "3\." | grep -Po '\d{2}')
  CPU1_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU1_TEMPERATURE_INDEX;}")
  CPU2_TEMPERATURE=$(echo $CPU_DATA | awk "{print \$$CPU2_TEMPERATURE_INDEX;}")
  if ! [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]]; then
    CPU2_TEMPERATURE="-"
  fi

  INLET_TEMPERATURE=$(echo "$DATA" | grep Inlet | grep -Po '\d{2}' | tail -1)
  EXHAUST_TEMPERATURE=$(echo "$DATA" | grep Exhaust | grep -Po '\d{2}' | tail -1)
  if [ -z "$EXHAUST_TEMPERATURE" ]; then EXHAUST_TEMPERATURE="-"; fi

  # Fan RPM average
  local FAN_DATA
  FAN_DATA=$(ipmitool -I $IDRAC_LOGIN_STRING sdr type Fan 2>/dev/null | grep RPM | grep -Po '\d{3,5} RPM' | grep -Po '\d+')
  if [ -n "$FAN_DATA" ]; then
    local FAN_TOTAL=0 FAN_COUNT=0
    while IFS= read -r rpm; do
      FAN_TOTAL=$(( FAN_TOTAL + rpm ))
      (( FAN_COUNT++ ))
    done <<< "$FAN_DATA"
    AVERAGE_FAN_RPM=$(( FAN_COUNT > 0 ? FAN_TOTAL / FAN_COUNT : 0 ))
  else
    AVERAGE_FAN_RPM=0
  fi
}

function log_to_csv() {
  local TIMESTAMP
  TIMESTAMP="$(date +"%Y-%m-%d %T")"
  local CSV_FILE="$LOG_DIR/fan_controller.csv"
  local STATUS_FILE="$LOG_DIR/status.json"

  mkdir -p "$LOG_DIR"
  if [ ! -f "$CSV_FILE" ]; then
    echo "timestamp,inlet_temp,cpu1_temp,cpu2_temp,exhaust_temp,fan_profile,fan_speed_pct,avg_fan_rpm" > "$CSV_FILE"
  fi

  local FAN_SPEED_PCT
  FAN_SPEED_PCT=$(echo "$CURRENT_FAN_CONTROL_PROFILE" | grep -Po '\d+(?=%)' | head -1)
  [ -z "$FAN_SPEED_PCT" ] && FAN_SPEED_PCT=100

  local CPU2_VAL="$CPU2_TEMPERATURE"
  [[ ! "$CPU2_VAL" =~ ^[0-9]+$ ]] && CPU2_VAL=""
  local EXHAUST_VAL="$EXHAUST_TEMPERATURE"
  [[ ! "$EXHAUST_VAL" =~ ^[0-9]+$ ]] && EXHAUST_VAL=""

  local OVERRIDE_ACTIVE="false"
  [ -f "$LOG_DIR/fan_override" ] && OVERRIDE_ACTIVE="true"

  echo "${TIMESTAMP},${INLET_TEMPERATURE},${CPU1_TEMPERATURE},${CPU2_VAL},${EXHAUST_VAL},${CURRENT_FAN_CONTROL_PROFILE},${FAN_SPEED_PCT},${AVERAGE_FAN_RPM}" >> "$CSV_FILE"

  cat > "$STATUS_FILE" << JSONEOF
{
  "timestamp": "${TIMESTAMP}",
  "inlet_temp": ${INLET_TEMPERATURE},
  "cpu1_temp": ${CPU1_TEMPERATURE},
  "cpu2_temp": "${CPU2_VAL}",
  "exhaust_temp": "${EXHAUST_VAL}",
  "fan_profile": "${CURRENT_FAN_CONTROL_PROFILE}",
  "fan_speed_pct": ${FAN_SPEED_PCT},
  "avg_fan_rpm": ${AVERAGE_FAN_RPM},
  "override_active": ${OVERRIDE_ACTIVE},
  "server_model": "${SERVER_MODEL:-}"
}
JSONEOF

  # Prune old entries
  local CUTOFF
  CUTOFF=$(date -d "-${LOG_RETENTION_DAYS} days" +"%Y-%m-%d %T" 2>/dev/null)
  if [ -n "$CUTOFF" ]; then
    awk -v cutoff="$CUTOFF" 'NR==1 || $0 >= cutoff' "$CSV_FILE" > "${CSV_FILE}.tmp" && mv "${CSV_FILE}.tmp" "$CSV_FILE"
  fi
}

function graceful_exit() {
  echo "$(date): Shutting down - restoring Dell default fan control" >> "$LOG_FILE"
  ipmitool -I $IDRAC_LOGIN_STRING raw 0x30 0x30 0x01 0x01 > /dev/null 2>&1
  rm -f "$PID_FILE"
  exit 0
}

trap 'graceful_exit' SIGINT SIGQUIT SIGTERM

# ---------------------------------------------------------------------------
# Validate and convert FAN_SPEED
# ---------------------------------------------------------------------------
if [[ "$FAN_SPEED" == 0x* ]]; then
  DECIMAL_FAN_SPEED=$(convert_hexadecimal_value_to_decimal "$FAN_SPEED")
else
  DECIMAL_FAN_SPEED="$FAN_SPEED"
fi

# ---------------------------------------------------------------------------
# Connect and verify Dell server
# ---------------------------------------------------------------------------
echo "$(date): Starting iDRAC Fan Controller" >> "$LOG_FILE"

FRU=$(ipmitool -I $IDRAC_LOGIN_STRING fru 2>/dev/null)
SERVER_MANUFACTURER=$(echo "$FRU" | grep "Product Manufacturer" | awk -F ': ' '{print $2}')
SERVER_MODEL=$(echo "$FRU" | grep "Product Name" | awk -F ': ' '{print $2}')

if [[ ! "$SERVER_MANUFACTURER" == "DELL" ]]; then
  echo "$(date): ERROR - Server is not a Dell product. Exiting." >> "$LOG_FILE"
  rm -f "$PID_FILE"
  exit 1
fi

# Gen 14+ detection
if [[ $SERVER_MODEL =~ .*[RT][[:space:]]?[0-9][4-9]0.* ]]; then
  CPU1_TEMPERATURE_INDEX=2
  CPU2_TEMPERATURE_INDEX=4
else
  CPU1_TEMPERATURE_INDEX=1
  CPU2_TEMPERATURE_INDEX=2
fi

echo "$(date): Server: $SERVER_MANUFACTURER $SERVER_MODEL" >> "$LOG_FILE"
echo "$(date): Mode: $FAN_CONTROL_MODE | Threshold: ${CPU_TEMPERATURE_THRESHOLD}C" >> "$LOG_FILE"

# ---------------------------------------------------------------------------
# Initialise
# ---------------------------------------------------------------------------
IS_DELL_DEFAULT_FAN_CONTROL_PROFILE_APPLIED=true
retrieve_temperatures

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
while true; do
  OVERRIDE_FILE="$LOG_DIR/fan_override"
  if [ -f "$OVERRIDE_FILE" ]; then
    OVERRIDE_SPEED=$(cat "$OVERRIDE_FILE" | tr -d '[:space:]')
    if [[ "$OVERRIDE_SPEED" =~ ^[0-9]+$ ]]; then
      apply_user_fan_control_profile "$OVERRIDE_SPEED"
      CURRENT_FAN_CONTROL_PROFILE="Manual override (${OVERRIDE_SPEED}%)"
      log_to_csv
      sleep "$CHECK_INTERVAL"
      retrieve_temperatures
      continue
    fi
  fi

  if [[ "$CPU2_TEMPERATURE" =~ ^[0-9]+$ ]] && [ "$CPU2_TEMPERATURE" -gt "$CPU1_TEMPERATURE" ]; then
    MAX_CPU_TEMPERATURE=$CPU2_TEMPERATURE
  else
    MAX_CPU_TEMPERATURE=$CPU1_TEMPERATURE
  fi

  case "$FAN_CONTROL_MODE" in
    stepped)
      apply_stepped_fan_curve "$MAX_CPU_TEMPERATURE"
      ;;
    interpolate)
      apply_interpolated_fan_curve "$MAX_CPU_TEMPERATURE"
      ;;
    *)
      if [ "$MAX_CPU_TEMPERATURE" -gt "$CPU_TEMPERATURE_THRESHOLD" ]; then
        apply_Dell_default_fan_control_profile
      else
        apply_user_fan_control_profile
      fi
      ;;
  esac

  log_to_csv
  sleep "$CHECK_INTERVAL"
  retrieve_temperatures
done
