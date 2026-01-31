#!/bin/bash

#battery_monitor.sh
# ============================================
# LOGGING WRAPPER FOR LAUNCHAGENT
# ============================================
exec 1> >(while IFS= read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S')] $line"; done)
exec 2> >(while IFS= read -r line; do echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $line"; done >&2)

# ============================================
# OPTIMIZED EVENT-BASED BATTERY MONITOR
# ============================================
# Resource usage: <0.01% CPU, <0.01% battery/hour
# ============================================

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# VSCode terminal compatibility
: ${RPROMPT=}

# Manual test mode - run with: ./battery_monitor.sh --test
if [ $# -gt 0 ] && [ "$1" = "--test" ]; then
    echo "🧪 Running in TEST mode - forcing detailed check..."
    FORCE_FULL_CHECK=1
    
    # Get current cycle and subtract 1 to simulate increase
    REAL_CYCLE=$(system_profiler SPPowerDataType | grep "Cycle Count" | awk '{print $3}')
    LAST_CYCLE=$((REAL_CYCLE - 1))  # Simulate previous cycle
    LAST_PCT="50"
    LAST_STATUS="Battery Power"
    LAST_CHECK_TIME=0
    
    echo "   Simulating cycle increase: $LAST_CYCLE → $REAL_CYCLE"
fi

DEBUG=${DEBUG:-0}
debug_log() {
    [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*" >&2
}

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_debug() {
    [ "$DEBUG" -eq 1 ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >&2
}

# Show stats - run with: ./battery_monitor.sh --stats
if [ "${1:-}" = "--stats" ]; then
    STATE_FILE="$HOME/battery/.battery_state"
    LOG_FILE="$HOME/battery/.battery_monitor.log"
    CACHE_FILE="$HOME/battery/.battery_cache"
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 BATTERY MONITOR STATISTICS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    
    echo "⚡ CURRENT STATUS:"
    CURRENT_PCT=$(pmset -g batt | grep -Eo "[0-9]+%" | cut -d% -f1)
    CURRENT_STATUS=$(pmset -g batt | grep -o "AC Power\|Battery Power")
    CURRENT_CYCLE=$(system_profiler SPPowerDataType | grep "Cycle Count" | awk '{print $3}')
    HEALTH_PCT=$(ioreg -r -c "AppleSmartBattery" | grep '"AppleRawMaxCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r ')
    DESIGN_CAP=$(ioreg -r -c "AppleSmartBattery" | grep '"DesignCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r ')
    if [ -n "$HEALTH_PCT" ] && [ -n "$DESIGN_CAP" ] && [ "$DESIGN_CAP" -gt 0 ] 2>/dev/null; then
        HEALTH=$(echo "scale=1; ($HEALTH_PCT / $DESIGN_CAP) * 100" | bc)
    else
        HEALTH="N/A"
    fi
    TEMP_RAW=$(ioreg -r -c "AppleSmartBattery" | grep '"Temperature"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r ')
    if [ -n "$TEMP_RAW" ]; then
        TEMP=$(echo "scale=1; $TEMP_RAW / 100" | bc)
    else
        TEMP="N/A"
    fi
    
    echo "  Battery Level:  $CURRENT_PCT%"
    echo "  Power Source:   $CURRENT_STATUS"
    echo "  Cycle Count:    $CURRENT_CYCLE"
    echo "  Health:         $HEALTH%"
    echo "  Temperature:    ${TEMP}°C"
    echo ""
    
    echo "📁 FILE STATUS:"
    if [ -f "$LOG_FILE" ]; then
        LOG_LINES=$(wc -l < "$LOG_FILE")
        LOG_SIZE=$(du -h "$LOG_FILE" | awk '{print $1}')
        LAST_ENTRY=$(tail -1 "$LOG_FILE" 2>/dev/null || echo "No entries")
        echo "  Log Entries:    $LOG_LINES lines ($LOG_SIZE)"
        echo "  Last Entry:     $LAST_ENTRY"
    else
        echo "  Log File:       Not created yet"
    fi
    
    if [ -f "$CACHE_FILE" ]; then
        CURRENT_TIME_STATS=$(date +%s)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            CACHE_MTIME=$(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0)
        else
            CACHE_MTIME=$(stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)
        fi
        CACHE_AGE=$(( (CURRENT_TIME_STATS - CACHE_MTIME) / 60 ))
        echo "  Cache Age:      ${CACHE_AGE} minutes"
    else
        echo "  Cache:          No cache"
    fi
    
    if [ -f "$STATE_FILE" ]; then
        source "$STATE_FILE"
        echo "  Last Check:     $(date -r $LAST_CHECK_TIME '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'Never')"
        echo "  Last Cycle:     $LAST_CYCLE"
    else
        echo "  State File:     Not created yet"
    fi
    
    echo ""
    echo "📝 RECENT EVENTS (Last 5):"
    if [ -f "$LOG_FILE" ]; then
        tail -5 "$LOG_FILE" | sed 's/^/  /'
    else
        echo "  No log entries yet"
    fi
    
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi


# ============================================
# GRACEFUL SHUTDOWN HANDLER
# ============================================
cleanup() {
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Battery Monitor Stopped (PID: $$)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    # Save emergency state    
    cat > "$STATE_FILE" <<EOF
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# BATTERY MONITOR STATE (Auto-saved)
# Last Check: $(date '+%Y-%m-%d %H:%M:%S')
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

LAST_PCT="${CURRENT_PCT:-}"
LAST_STATUS="${CURRENT_STATUS:-}"
LAST_CYCLE="${CURRENT_CYCLE:-0}"
LAST_CHECK_TIME=$(date +%s)
EOF
    exit 0
}
trap cleanup EXIT SIGINT SIGTERM

# ============================================
# ENSURE REQUIRED DIRECTORIES EXIST
# ============================================
mkdir -p "$HOME/battery"

for cmd in pmset ioreg system_profiler bc; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    }
done

# ============================================
# CACHE SYSTEM FOR EXPENSIVE DATA
# ============================================
CACHE_FILE="$HOME/battery/.battery_cache"
CACHE_DURATION=3600  # 60 minutes

load_cached_data() {

    if [ -f "$CACHE_FILE" ]; then
        # shellcheck disable=SC1090
        # Validate file format before sourcing
        if grep -qE '^[A-Z_]+=[^;`$]*$' "$CACHE_FILE" 2>/dev/null; then
            source "$CACHE_FILE" 2>/dev/null || return 1
        else
            rm -f "$CACHE_FILE"  # Remove corrupted cache
            return 1
        fi
        
        # Validate required variables
        if [ -z "${CACHE_TIME:-}" ] || ! [[ "$CACHE_TIME" =~ ^[0-9]+$ ]] || \
            [ -z "${CACHED_HEALTH:-}" ] || [ -z "${CACHED_MAX_CAP:-}" ]; then
                return 1
        fi
        # Check if CACHE_TIME was actually loaded
        if [ -n "$CACHE_TIME" ]; then
            local cache_age=$((CURRENT_TIME - CACHE_TIME))
            if [ $cache_age -lt $CACHE_DURATION ]; then
                return 0  # Cache is fresh
            fi
        fi
    fi
    return 1  # Cache expired or missing
}

save_cached_data() {
    cat > "$CACHE_FILE" <<EOF
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# BATTERY DATA CACHE (Auto-generated)
# Last Updated: $(date '+%Y-%m-%d %H:%M:%S')
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

CACHE_TIME=$CURRENT_TIME

# Battery Health
CACHED_HEALTH="$HEALTH"
CACHED_HEALTH_PCT="$(get_health_percentage)"

# Capacity (mAh)
CACHED_MAX_CAP="$MAX_CAP"
CACHED_CURRENT_CAP="$CURRENT_CAP"
CACHED_DESIGN_CAP="$DESIGN_CAP"
CACHED_NOMINAL_CAP="$NOMINAL_CAP"

# Power Specs
CACHED_VOLTAGE="$VOLTAGE"
CACHED_AMPERAGE="$AMPERAGE"

# Battery Info
CACHED_BATTERY_SERIAL="$BATTERY_SERIAL"

# Note: Cache expires after 60 minutes
EOF
}

# ============================================
# NOTIFICATION THROTTLING
# ============================================
NOTIFICATION_FILE="$HOME/battery/.last_notification"

# Initialize notification file if missing
if [ ! -f "$NOTIFICATION_FILE" ]; then
    touch "$NOTIFICATION_FILE"
fi

should_notify() {
    local notification_type=$1
    local cooldown=$2  # seconds
    
    if [ -f "$NOTIFICATION_FILE" ]; then
        # Validate before sourcing
        if grep -qE '^LAST_[A-Z_]+_TIME=[0-9]+$' "$NOTIFICATION_FILE" 2>/dev/null; then
            # shellcheck disable=SC1090
            source "$NOTIFICATION_FILE" 2>/dev/null || true
        fi
        local last_time_var="LAST_${notification_type}_TIME"
        local last_time=${!last_time_var:-0}
        local time_since=$((CURRENT_TIME - last_time))
        
        if [ $time_since -lt $cooldown ]; then
            return 1  # Don't notify yet
        fi
    fi
    
    # Update notification timestamp
    {
        grep -v "^LAST_${notification_type}_TIME=" "$NOTIFICATION_FILE" 2>/dev/null || true
        echo "LAST_${notification_type}_TIME=$CURRENT_TIME"
    } > "${NOTIFICATION_FILE}.tmp" && mv "${NOTIFICATION_FILE}.tmp" "$NOTIFICATION_FILE"
    
    return 0  # OK to notify
}


# Configuration
BATTERY_DIR="${BATTERY_DIR:-$HOME/battery}"
STATE_FILE="$BATTERY_DIR/.battery_state"
LOG_FILE="$BATTERY_DIR/.battery_monitor.log"

# ============================================
# QUICK CHECK - Run first (very fast)
# ============================================
CURRENT_PCT=$(pmset -g batt 2>/dev/null | grep -Eo "[0-9]+%" | cut -d% -f1)
if [ -z "$CURRENT_PCT" ]; then
    log_error "Failed to get battery percentage - pmset command failed"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ❌ Failed to get battery percentage" >> "$LOG_FILE"
    exit 1
fi
CURRENT_STATUS=$(pmset -g batt | grep -o "AC Power\|Battery Power")
CURRENT_TIME=$(date +%s)


# ============================================
# DETECT WAKE FROM SLEEP / SIGNIFICANT CHANGES
# ============================================
FORCE_FULL_CHECK=${FORCE_FULL_CHECK:-0}

# Detect if system was asleep (significant time gap)
if [ -f "$STATE_FILE" ]; then
    source "$STATE_FILE"
    TIME_ELAPSED=$((CURRENT_TIME - LAST_CHECK_TIME))
    
    # If more than 30 minutes elapsed, likely woke from sleep
    if [ "${TIME_ELAPSED:-0}" -gt 1800 ] 2>/dev/null; then
        HOURS_ASLEEP=$((TIME_ELAPSED / 3600))
        MINUTES_ASLEEP=$(((TIME_ELAPSED % 3600) / 60))
        
        # Always log wake from sleep
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 WAKE FROM SLEEP DETECTED" >> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 Sleep Duration: ${HOURS_ASLEEP}h ${MINUTES_ASLEEP}m (${TIME_ELAPSED}s total)" >> "$LOG_FILE"
        
        # Check if battery drained during sleep
        if [ "$CURRENT_PCT" != "$LAST_PCT" ]; then
            PCT_CHANGE=$((CURRENT_PCT - LAST_PCT))
            
            if [ "${PCT_CHANGE:-0}" -lt 0 ] 2>/dev/null; then
                # Battery drained during sleep
                DRAIN_AMOUNT=${PCT_CHANGE#-}
                DRAIN_RATE_PER_HOUR=$(echo "scale=2; ($DRAIN_AMOUNT * 3600) / $TIME_ELAPSED" | bc 2>/dev/null || echo "0")
                
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 Battery DRAINED during sleep:" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Before sleep: ${LAST_PCT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   After sleep:  ${CURRENT_PCT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Total drain:  ${DRAIN_AMOUNT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Drain rate:   ${DRAIN_RATE_PER_HOUR}%/hour" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Power source: ${LAST_STATUS} → ${CURRENT_STATUS}" >> "$LOG_FILE"
                
                # Check for threshold crossings during sleep
                CROSSED_THRESHOLDS=""
                
                # Check 80% crossing
                if [ "$LAST_PCT" -gt 80 ] 2>/dev/null && [ "$CURRENT_PCT" -le 80 ] 2>/dev/null; then
                    CROSSED_THRESHOLDS="${CROSSED_THRESHOLDS}80%, "
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   ⚠️  CROSSED 80% threshold during sleep!" >> "$LOG_FILE"
                fi
                
                # Check 50% crossing
                if [ "$LAST_PCT" -gt 50 ] 2>/dev/null && [ "$CURRENT_PCT" -le 50 ] 2>/dev/null; then
                    CROSSED_THRESHOLDS="${CROSSED_THRESHOLDS}50%, "
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   ⚠️  CROSSED 50% threshold during sleep!" >> "$LOG_FILE"
                fi
                
                # Check 20% crossing
                if [ "$LAST_PCT" -gt 20 ] 2>/dev/null && [ "$CURRENT_PCT" -le 20 ] 2>/dev/null; then
                    CROSSED_THRESHOLDS="${CROSSED_THRESHOLDS}20%, "
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   🚨 CROSSED 20% threshold during sleep!" >> "$LOG_FILE"
                fi
                
                # Remove trailing comma
                CROSSED_THRESHOLDS=${CROSSED_THRESHOLDS%, }
                
                # Show notification for significant drain (>5%) OR threshold crossing
                if [ "${DRAIN_AMOUNT}" -gt 5 ] 2>/dev/null || [ -n "$CROSSED_THRESHOLDS" ]; then
                    if should_notify "SLEEP_DRAIN" 3600; then
                        NOTIFICATION_MSG="Battery drained ${DRAIN_AMOUNT}% while asleep (${LAST_PCT}% → ${CURRENT_PCT}%)"
                        if [ -n "$CROSSED_THRESHOLDS" ]; then
                            NOTIFICATION_MSG="${NOTIFICATION_MSG}. Crossed: ${CROSSED_THRESHOLDS}"
                        fi
                        
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 📢 Sending sleep drain notification" >> "$LOG_FILE"
                        osascript -e "display notification \"${NOTIFICATION_MSG}\" with title \"⚠️ Sleep Battery Drain (${HOURS_ASLEEP}h ${MINUTES_ASLEEP}m)\" subtitle \"Drain rate: ${DRAIN_RATE_PER_HOUR}%/hour\" sound name \"Basso\"" 2>> "$LOG_FILE"
                        
                        if [ $? -eq 0 ]; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 ✅ Notification sent successfully" >> "$LOG_FILE"
                        else
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 ❌ Notification failed" >> "$LOG_FILE"
                        fi
                    else
                        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 🔕 Notification skipped (cooldown active)" >> "$LOG_FILE"
                    fi
                fi
                
            elif [ "${PCT_CHANGE:-0}" -gt 0 ] 2>/dev/null; then
                # Battery charged during sleep
                CHARGE_AMOUNT=$PCT_CHANGE
                
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 Battery CHARGED during sleep:" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Before sleep: ${LAST_PCT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   After sleep:  ${CURRENT_PCT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Total charge: +${CHARGE_AMOUNT}%" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Power source: ${LAST_STATUS} → ${CURRENT_STATUS}" >> "$LOG_FILE"
                
            else
                # No battery change during sleep
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 Battery level UNCHANGED during sleep (${CURRENT_PCT}%)" >> "$LOG_FILE"
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Power source: ${CURRENT_STATUS}" >> "$LOG_FILE"
            fi
        else
            # No battery data from before sleep
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 No previous battery data to compare" >> "$LOG_FILE"
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤   Current level: ${CURRENT_PCT}%" >> "$LOG_FILE"
        fi
        
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 💤 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "$LOG_FILE"
        echo "" >> "$LOG_FILE"
        
        FORCE_FULL_CHECK=1
    fi
else
    LAST_PCT=""
    LAST_STATUS=""
    LAST_CYCLE="0"
    LAST_CHECK_TIME=0
fi

# Skip if nothing changed (saves 99% of CPU cycles)
if [ $FORCE_FULL_CHECK -eq 0 ]; then
    if [ "$CURRENT_PCT" == "$LAST_PCT" ] && [ "$CURRENT_STATUS" == "$LAST_STATUS" ]; then
        # Also skip if checked in last 5 minutes (rate limiting)
        if [ "$((CURRENT_TIME - ${LAST_CHECK_TIME:-0}))" -lt 300 ] 2>/dev/null; then
            # Update timestamp only
            cat > "$STATE_FILE" <<EOF
LAST_PCT="$CURRENT_PCT"
LAST_STATUS="$CURRENT_STATUS"
LAST_CYCLE="$LAST_CYCLE"
LAST_CHECK_TIME=$CURRENT_TIME
EOF
            exit 0
        fi
    fi
fi


# ============================================
# INITIALIZE CACHE (if needed for this run)
# ============================================
# Variables will be populated from cache or fetched fresh when needed
HEALTH=""
MAX_CAP=""
CURRENT_CAP=""
DESIGN_CAP=""
VOLTAGE=""
AMPERAGE=""
BATTERY_SERIAL=""
NOMINAL_CAP=""

# ============================================
# HELPER FUNCTIONS
# ============================================

# Extract value from nested BatteryData/LifetimeData
extract_nested_value() {
    local key=$1
    local source=$2
    
    if [ "$source" == "LifetimeData" ]; then
        # Extract from LifetimeData section
        ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
        grep -A 100 "<key>LifetimeData</key>" | \
        grep "<key>${key}</key>" -A 1 | \
        grep "<integer>" | \
        sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
        head -1
    else
        # Extract from BatteryData section
        ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
        grep -A 200 "<key>BatteryData</key>" | \
        grep "<key>${key}</key>" -A 1 | \
        grep "<integer>" | \
        sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
        head -1
    fi
}

# Basic functions (fast)
get_cycle_count() {
    system_profiler SPPowerDataType | grep "Cycle Count" | awk '{print $3}'
}

get_battery_health() {
    system_profiler SPPowerDataType | grep "Condition" | awk '{print $2}'
}

get_max_capacity() {
    ioreg -r -c "AppleSmartBattery" | grep '"AppleRawMaxCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r '
}

get_current_capacity() {
    ioreg -r -c "AppleSmartBattery" | grep '"AppleRawCurrentCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r '
}

get_design_capacity() {
    ioreg -r -c "AppleSmartBattery" | grep '"DesignCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r '
}

get_health_percentage() {
    local max_cap=$(get_max_capacity)
    local design_cap=$(get_design_capacity)
    if [ -n "$max_cap" ] && [ -n "$design_cap" ] && [ "$design_cap" -gt 0 ] 2>/dev/null; then
        command -v bc >/dev/null 2>&1 || { echo "Error: bc is required but not installed." >&2; exit 1; }
        echo "scale=1; ($max_cap / $design_cap) * 100" | bc | tr -d '\n\r '
    else
        echo "N/A"
    fi
}

get_battery_temp() {
    local temp=$(ioreg -r -c "AppleSmartBattery" | grep '"Temperature"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r ')
    if [ -n "$temp" ]; then
        echo "scale=1; $temp / 100" | bc | tr -d '\n\r '
    else
        echo "N/A"
    fi
}

get_voltage() {
    ioreg -r -c "AppleSmartBattery" | grep '"Voltage"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r '
}

get_amperage() {
    local raw_amperage=$(ioreg -r -c "AppleSmartBattery" | grep '"Amperage"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r ')
    
    # Validate we got a number
    if [ -z "$raw_amperage" ] || ! [[ "$raw_amperage" =~ ^[0-9]+$ ]]; then
        echo "0"
        return
    fi
    
    # Use bc for large number comparison and conversion (bash can't handle uint64)
    # Check if value is in upper half of uint64 (negative in 2's complement)
    local is_negative=$(echo "$raw_amperage > 9223372036854775807" | bc 2>/dev/null)
    
    if [ "$is_negative" = "1" ]; then
        # Convert from unsigned to signed using bc
        echo "$raw_amperage - 18446744073709551616" | bc 2>/dev/null
    else
        # Value is already positive or zero
        echo "$raw_amperage"
    fi
}

get_power_watts() {
    local voltage=$(get_voltage)
    local amperage=$(get_amperage)
    
    # Validate both are numeric
    if ! [[ "$voltage" =~ ^-?[0-9]+$ ]] 2>/dev/null || ! [[ "$amperage" =~ ^-?[0-9]+$ ]] 2>/dev/null; then
        echo "N/A"
        return
    fi
    
    if [ -n "$voltage" ] && [ -n "$amperage" ]; then
        # Calculate absolute value of power
        local power=$(echo "$voltage $amperage" | awk '{printf "%.2f", ($1 * $2) / 1000000}')
        # Remove negative sign if present
        echo "${power#-}"
    else
        echo "0.00"
    fi
}

get_charge_rate() {
    local amperage=$(get_amperage)
    if [ -n "$amperage" ] && [ "$amperage" != "N/A" ]; then
        if [ "$amperage" -gt 0 ] 2>/dev/null; then
            echo "+${amperage}mA (Charging)"
        elif [ "$amperage" -lt 0 ] 2>/dev/null; then
            echo "${amperage}mA (Discharging)"
        else
            echo "0mA (Idle)"
        fi
    else
        echo "N/A"
    fi
}

get_time_remaining() {
    pmset -g batt | grep -Eo "[0-9]+:[0-9]+ remaining" | sed 's/ remaining//'
}

get_battery_serial() {
    ioreg -r -c "AppleSmartBattery" | grep '"Serial"' | grep -v 'BatteryData' | sed 's/.*"\([^"]*\)".*/\1/' | tr -d '\n\r '
}

get_state_of_charge() {
    extract_nested_value "StateOfCharge" "BatteryData"
}

get_nominal_capacity() {
    ioreg -r -c "AppleSmartBattery" | grep '"NominalChargeCapacity"' | sed 's/.*= \([0-9]*\).*/\1/' | tr -d '\n\r '
}

get_battery_charging_mode() {
    local flags=$(extract_nested_value "Flags" "BatteryData")
    if [ -n "$flags" ]; then
        if [ $((flags & 16777216)) -ne 0 ]; then
            echo "Optimized Charging Active"
        else
            echo "Normal Charging"
        fi
    else
        echo "N/A"
    fi
}

# Advanced functions (expensive - only call when needed)
get_cell_voltages() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 5 "<key>CellVoltage</key>" | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
    tr '\n' ',' | \
    sed 's/,$//' | \
    grep -E '^[0-9,]+$' || echo "N/A"
}

get_qmax_values() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 5 "<key>Qmax</key>" | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
    tr '\n' ',' | \
    sed 's/,$//' | \
    grep -E '^[0-9,]+$' || echo "N/A"
}

get_present_dod() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 5 "<key>PresentDOD</key>" | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
    tr '\n' ',' | \
    sed 's/,$//' | \
    grep -E '^[0-9,]+$' || echo "N/A"
}

get_weighted_ra() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 5 "<key>WeightedRa</key>" | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/' | \
    tr '\n' ',' | \
    sed 's/,$//' | \
    grep -E '^[0-9,]+$' || echo "N/A"
}

get_total_operating_time() {
    local minutes=$(extract_nested_value "TotalOperatingTime" "LifetimeData")
    if [ -n "$minutes" ]; then
        local hours=$((minutes / 60))
        local days=$((hours / 24))
        local remaining_hours=$((hours % 24))
        echo "${days}d ${remaining_hours}h (${hours}h total)"
    else
        echo "N/A"
    fi
}

get_temp_extremes() {
    local min_temp=$(extract_nested_value "MinimumTemperature" "LifetimeData")
    local max_temp=$(extract_nested_value "MaximumTemperature" "LifetimeData")
    local avg_temp=$(extract_nested_value "AverageTemperature" "LifetimeData")
    
    if [ -n "$min_temp" ] && [ -n "$max_temp" ] && [ -n "$avg_temp" ]; then
        local min_c=$(echo "scale=1; $min_temp / 10" | bc)
        local max_c=$(echo "scale=1; $max_temp / 10" | bc)
        local avg_c=$(echo "scale=1; $avg_temp / 10" | bc)
        echo "Min: ${min_c}°C, Avg: ${avg_c}°C, Max: ${max_c}°C"
    else
        echo "N/A"
    fi
}

get_voltage_extremes() {
    local min_v=$(extract_nested_value "MinimumPackVoltage" "LifetimeData")
    local max_v=$(extract_nested_value "MaximumPackVoltage" "LifetimeData")
    
    if [ -n "$min_v" ] && [ -n "$max_v" ]; then
        echo "Min: ${min_v}mV, Max: ${max_v}mV"
    else
        echo "N/A"
    fi
}

get_current_extremes() {
    local max_charge=$(extract_nested_value "MaximumChargeCurrent" "LifetimeData")
    local max_discharge_raw=$(extract_nested_value "MaximumDischargeCurrent" "LifetimeData")
    
    local max_discharge="N/A"
    if [ -n "$max_discharge_raw" ] && [ "$max_discharge_raw" != "N/A" ]; then
        # Convert using bc if available
        if command -v bc >/dev/null 2>&1; then
            max_discharge=$(echo "$max_discharge_raw - 2^64" | bc 2>/dev/null || echo "N/A")
        else
            # Bash fallback (may not work on 32-bit systems)
            max_discharge=$((max_discharge_raw - 18446744073709551616)) 2>/dev/null || echo "N/A"
        fi
    fi
    
    if [ -n "$max_charge" ] && [ "$max_discharge" != "N/A" ]; then
        echo "Max Charge: ${max_charge}mA, Max Discharge: ${max_discharge}mA"
    else
        echo "N/A"
    fi
}

get_last_calibration_cycle() {
    extract_nested_value "CycleCountLastQmax" "LifetimeData"
}

get_daily_soc_range() {
    local min_soc=$(extract_nested_value "DailyMinSoc" "BatteryData")
    local max_soc=$(extract_nested_value "DailyMaxSoc" "BatteryData")
    if [ -n "$min_soc" ] && [ -n "$max_soc" ]; then
        echo "Min: ${min_soc}%, Max: ${max_soc}%"
    else
        echo "N/A"
    fi
}

get_chemistry_id() {
    extract_nested_value "ChemID" "BatteryData"
}

get_passed_charge() {
    extract_nested_value "PassedCharge" "BatteryData"
}

get_temp_samples() {
    extract_nested_value "TemperatureSamples" "LifetimeData"
}

get_dataflash_writes() {
    extract_nested_value "DataFlashWriteCount" "BatteryData"
}

get_instant_standby() {
    extract_nested_value "ISS" "BatteryData"
}

get_manufacture_date_detailed() {
    local raw_date=$(extract_nested_value "ManufactureDate" "BatteryData")
    
    # Validate we got a number
    if [ -z "$raw_date" ] || ! [[ "$raw_date" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return
    fi
    
    local day=$(( raw_date & 0x1F ))
    local month=$(( (raw_date >> 5) & 0x0F ))
    local year=$(( ((raw_date >> 9) & 0x7F) + 2000 ))  # Changed from 1980 to 2000
    
    # Validate month
    if [ "$month" -lt 1 ] || [ "$month" -gt 12 ]; then
        echo "N/A"
        return
    fi
    
    local months=("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")
    local month_name=${months[$month]}
    
    echo "$day $month_name $year"
}

get_estimated_lifespan() {
    local cycles=$(get_cycle_count)
    local max_cycles=1000
    if [ -n "$cycles" ]; then
        local remaining=$((max_cycles - cycles))
        local percentage=$((100 * remaining / max_cycles))
        echo "${percentage}% (~${remaining} cycles remaining)"
    else
        echo "N/A"
    fi
}

# Fetch multiple values in parallel (background jobs)
# Fetch advanced data sequentially (only called on cycle increase - rare event)
fetch_advanced_data() {
    CELL_VOLTAGES=$(get_cell_voltages 2>/dev/null || echo "N/A")
    QMAX_VALUES=$(get_qmax_values 2>/dev/null || echo "N/A")
    PRESENT_DOD=$(get_present_dod 2>/dev/null || echo "N/A")
    WEIGHTED_RA=$(get_weighted_ra 2>/dev/null || echo "N/A")
    TOTAL_TIME=$(get_total_operating_time 2>/dev/null || echo "N/A")
    MFG_DATE=$(get_manufacture_date_detailed 2>/dev/null || echo "N/A")
    LIFESPAN=$(get_estimated_lifespan 2>/dev/null || echo "N/A")
    
    # Ensure all have values
    CELL_VOLTAGES=${CELL_VOLTAGES:-N/A}
    QMAX_VALUES=${QMAX_VALUES:-N/A}
    PRESENT_DOD=${PRESENT_DOD:-N/A}
    WEIGHTED_RA=${WEIGHTED_RA:-N/A}
    TOTAL_TIME=${TOTAL_TIME:-N/A}
    MFG_DATE=${MFG_DATE:-N/A}
    LIFESPAN=${LIFESPAN:-N/A}
}

# ============================================
# ADDITIONAL MONITORING FUNCTIONS
# ============================================

# Lifetime Extremes (Stress Indicators)
get_max_temp_ever() {
    local max_temp=$(extract_nested_value "MaximumTemperature" "LifetimeData")
    if [ -n "$max_temp" ]; then
        echo "scale=1; $max_temp / 10" | bc 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

get_min_temp_ever() {
    local min_temp=$(extract_nested_value "MinimumTemperature" "LifetimeData")
    if [ -n "$min_temp" ]; then
        echo "scale=1; $min_temp / 10" | bc 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

get_avg_temp_lifetime() {
    local avg_temp=$(extract_nested_value "AverageTemperature" "LifetimeData")
    if [ -n "$avg_temp" ]; then
        echo "scale=1; $avg_temp / 10" | bc 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

get_max_pack_voltage_ever() {
    extract_nested_value "MaximumPackVoltage" "LifetimeData"
}

get_min_pack_voltage_ever() {
    extract_nested_value "MinimumPackVoltage" "LifetimeData"
}

get_max_charge_current_ever() {
    extract_nested_value "MaximumChargeCurrent" "LifetimeData"
}

get_max_discharge_current_ever() {
    local raw=$(extract_nested_value "MaximumDischargeCurrent" "LifetimeData")
    
    if [ -z "$raw" ] || [ "$raw" = "N/A" ] || ! [[ "$raw" =~ ^[0-9]+$ ]]; then
        echo "N/A"
        return
    fi
    
    # Use bc for large number comparison and conversion (same as get_amperage)
    local is_negative=$(echo "$raw > 9223372036854775807" | bc 2>/dev/null)
    
    if [ "$is_negative" = "1" ]; then
        # Convert from unsigned to signed using bc
        echo "$raw - 18446744073709551616" | bc 2>/dev/null || echo "N/A"
    else
        # Value is already positive or zero
        echo "$raw"
    fi
}

# Calibration & Maintenance
get_last_qmax_calibration_cycle() {
    extract_nested_value "CycleCountLastQmax" "LifetimeData"
}

get_total_runtime() {
    local minutes=$(extract_nested_value "TotalOperatingTime" "LifetimeData")
    if [ -n "$minutes" ]; then
        local hours=$((minutes / 60))
        local days=$((hours / 24))
        local remaining_hours=$((hours % 24))
        echo "${days}d ${remaining_hours}h (${hours}h total)"
    else
        echo "N/A"
    fi
}

get_temperature_samples() {
    extract_nested_value "TemperatureSamples" "LifetimeData"
}

get_dataflash_write_count() {
    extract_nested_value "DataFlashWriteCount" "BatteryData"
}

# Daily Patterns
get_daily_max_soc() {
    extract_nested_value "DailyMaxSoc" "BatteryData"
}

get_daily_min_soc() {
    extract_nested_value "DailyMinSoc" "BatteryData"
}

# Cell Resistance (already have WeightedRa, adding more)
get_chemical_weighted_ra() {
    extract_nested_value "ChemicalWeightedRa" "BatteryData"
}

# Charging Mode Details
get_charging_flags() {
    extract_nested_value "Flags" "BatteryData"
}

get_charging_voltage() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 2 "<key>ChargerData</key>" | \
    grep -A 20 "<dict>" | \
    grep "<key>ChargingVoltage</key>" -A 1 | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/'
}

get_not_charging_reason() {
    ioreg -r -c "AppleSmartBattery" -a 2>/dev/null | \
    grep -A 2 "<key>ChargerData</key>" | \
    grep -A 20 "<dict>" | \
    grep "<key>NotChargingReason</key>" -A 1 | \
    grep "<integer>" | \
    sed 's/.*<integer>\(.*\)<\/integer>/\1/'
}

# Cell Voltage Analysis
get_cell_voltage_stats() {
    local voltages=$(get_cell_voltages)
    
    if [ "$voltages" == "N/A" ]; then
        echo "N/A"
        return
    fi
    
    # Split into array
    IFS=',' read -ra CELL_ARRAY <<< "$voltages"
    
    # Find min and max
    local min=${CELL_ARRAY[0]}
    local max=${CELL_ARRAY[0]}
    local sum=0
    
    for v in "${CELL_ARRAY[@]}"; do
        if [ "$v" -lt "$min" ] 2>/dev/null; then min=$v; fi
        if [ "$v" -gt "$max" ] 2>/dev/null; then max=$v; fi
        sum=$((sum + v))
    done
    
    local avg=$((sum / ${#CELL_ARRAY[@]}))
    local diff=$((max - min))
    
    echo "Min:${min}mV Max:${max}mV Avg:${avg}mV Diff:${diff}mV"
}

# Check if battery needs calibration
needs_calibration() {
    local current_cycle=$(get_cycle_count)
    local last_cal_cycle=$(get_last_qmax_calibration_cycle)
    
    if [ -n "$current_cycle" ] && [ -n "$last_cal_cycle" ]; then
        local cycles_since_cal=$((current_cycle - last_cal_cycle))
        if [ "$cycles_since_cal" -gt 50 ]; then
            echo "YES - ${cycles_since_cal} cycles since last calibration"
        else
            echo "NO - ${cycles_since_cal} cycles since last calibration"
        fi
    else
        echo "N/A"
    fi
}

show_notification() {
    local title=$1
    local message=$2
    local buttons=${3:-"OK"}
    local icon=${4:-"note"}
    
    osascript <<EOF
display dialog "$message" buttons {$buttons} default button "OK" with title "$title" with icon $icon
EOF
}

# ============================================
# MAIN LOGIC
# ============================================

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
log_info "Battery Monitor Started (PID: $$)"
log_info "Mode: ${1:-normal}"
log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Get current cycle count
CURRENT_CYCLE=$(get_cycle_count)

# Collect basic info (fast operations)
PERCENTAGE=$CURRENT_PCT
CHARGING=$CURRENT_STATUS
HEALTH_PCT=$(get_health_percentage)
TEMP=$(get_battery_temp)
TIME_REMAINING=$(get_time_remaining)

# Only log on state changes
LOG_ENTRY=""

# Check for percentage change
if [ "$CURRENT_PCT" != "$LAST_PCT" ]; then
    PCT_CHANGE=$((CURRENT_PCT - LAST_PCT))
    if [ "${PCT_CHANGE:-0}" -gt 0 ] 2>/dev/null; then
        LOG_ENTRY="$(date '+%Y-%m-%d %H:%M:%S') │ ↗️  ${LAST_PCT}% → ${CURRENT_PCT}% │ Health: $HEALTH_PCT% │ Temp: ${TEMP}°C │ $CHARGING"
    else
        LOG_ENTRY="$(date '+%Y-%m-%d %H:%M:%S') │ ↘️  ${LAST_PCT}% → ${CURRENT_PCT}% │ Health: $HEALTH_PCT% │ Temp: ${TEMP}°C │ $CHARGING"
    fi
fi

# Check for power source change
if [ "$CURRENT_STATUS" != "$LAST_STATUS" ]; then
    if [ -n "$LOG_ENTRY" ]; then
        LOG_ENTRY="$(date '+%Y-%m-%d %H:%M:%S') │ ↗️  ${LAST_PCT}% → ${CURRENT_PCT}% │ 🔌 ${LAST_STATUS} → ${CURRENT_STATUS} │ Health: $HEALTH_PCT% │ Temp: ${TEMP}°C"
    else
        LOG_ENTRY="$(date '+%Y-%m-%d %H:%M:%S') │ 🔌 ${LAST_STATUS} → ${CURRENT_STATUS} │ Battery: ${CURRENT_PCT}% │ Health: $HEALTH_PCT% │ Temp: ${TEMP}°C"
    fi
fi

# Write log entry if there's a change
if [ -n "$LOG_ENTRY" ]; then
    echo "$LOG_ENTRY" >> "$LOG_FILE"
fi

# ============================================
# CHECK FOR CYCLE INCREASE (RARE EVENT)
# ============================================
if [ $FORCE_FULL_CHECK -eq 1 ] || \
   ( [ -n "$CURRENT_CYCLE" ] && [ -n "$LAST_CYCLE" ] && \
     [ "$LAST_CYCLE" != "0" ] && \
     [ "${CURRENT_CYCLE:-0}" -gt "${LAST_CYCLE:-0}" ] 2>/dev/null ); then
    
    # In test mode, ensure we have a valid cycle
    if [ $FORCE_FULL_CHECK -eq 1 ] && [ -z "$LAST_CYCLE" ]; then
        LAST_CYCLE=$((CURRENT_CYCLE - 1))
    fi
    
    # Only log as "CYCLE INCREASED" if it actually increased (not just test mode)
    if [ -n "$CURRENT_CYCLE" ] && [ -n "$LAST_CYCLE" ] && \
       [ "$LAST_CYCLE" != "0" ] && \
       [ "${CURRENT_CYCLE:-0}" -gt "${LAST_CYCLE:-0}" ] 2>/dev/null; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔄 CYCLE INCREASED: $LAST_CYCLE → $CURRENT_CYCLE" >> "$LOG_FILE"
        
        # Send quick notification first
        osascript -e "display notification \"Cycle count increased to ${CURRENT_CYCLE}. Health: ${HEALTH_PCT}%\" with title \"🔋 Battery Cycle Increased\" subtitle \"${LAST_CYCLE} → ${CURRENT_CYCLE}\" sound name \"Glass\"" 2>> "$LOG_FILE"
    else
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔄 CYCLE CHECK (Test Mode): $LAST_CYCLE → $CURRENT_CYCLE" >> "$LOG_FILE"
    fi

    # Send quick notification first
    osascript -e "display notification \"Cycle count increased to ${CURRENT_CYCLE}. Health: ${HEALTH_PCT}%\" with title \"🔋 Battery Cycle Increased\" subtitle \"${LAST_CYCLE} → ${CURRENT_CYCLE}\" sound name \"Glass\"" 2>> "$LOG_FILE"

    
    # Fetch detailed info (expensive operations)
    # Try cache first, then fetch if needed
    if load_cached_data; then
        HEALTH="$CACHED_HEALTH"
        MAX_CAP="$CACHED_MAX_CAP"
        CURRENT_CAP="$CACHED_CURRENT_CAP"
        DESIGN_CAP="$CACHED_DESIGN_CAP"
        VOLTAGE="$CACHED_VOLTAGE"
        AMPERAGE="$CACHED_AMPERAGE"
        BATTERY_SERIAL="$CACHED_BATTERY_SERIAL"
        NOMINAL_CAP="$CACHED_NOMINAL_CAP"
    else
        # Cache miss - fetch fresh data
        HEALTH=$(get_battery_health)
        MAX_CAP=$(get_max_capacity)
        CURRENT_CAP=$(get_current_capacity)
        DESIGN_CAP=$(get_design_capacity)
        VOLTAGE=$(get_voltage)
        AMPERAGE=$(get_amperage)
        BATTERY_SERIAL=$(get_battery_serial)
        NOMINAL_CAP=$(get_nominal_capacity)
        save_cached_data
    fi

    # Always fetch these (they change frequently)
    POWER=$(get_power_watts)
    CHARGE_RATE=$(get_charge_rate)
    SOC=$(get_state_of_charge)
    BATTERY_MODE=$(get_battery_charging_mode)

    # NEW: Fetch additional monitoring data
    DAILY_MAX_SOC=$(get_daily_max_soc)
    DAILY_MIN_SOC=$(get_daily_min_soc)
    MAX_TEMP_EVER=$(get_max_temp_ever)
    MIN_TEMP_EVER=$(get_min_temp_ever)
    AVG_TEMP_LIFETIME=$(get_avg_temp_lifetime)
    LAST_CAL_CYCLE=$(get_last_qmax_calibration_cycle)
    TOTAL_RUNTIME=$(get_total_runtime)
    CELL_STATS=$(get_cell_voltage_stats)
    MAX_VOLT_EVER=$(get_max_pack_voltage_ever)
    MIN_VOLT_EVER=$(get_min_pack_voltage_ever)
    MAX_CHARGE_EVER=$(get_max_charge_current_ever)
    MAX_DISCHARGE_EVER=$(get_max_discharge_current_ever)

    # Advanced data (fetch in parallel for speed)
    fetch_advanced_data

    # Extended logging - write detailed info to log file
    echo "" >> "$LOG_FILE"

    echo "$(date '+%Y-%m-%d %H:%M:%S') | 🔄 CYCLE INCREASED: $LAST_CYCLE → $CURRENT_CYCLE" >> "$LOG_FILE"
    echo "📊 STATUS: Battery Level: $PERCENTAGE% (SoC:$SOC%) | Power Source: $CHARGING | Charging Mode: $BATTERY_MODE | Time Remaining: ${TIME_REMAINING:-N/A}" >> "$LOG_FILE"
    echo "🏥 HEALTH: Condition: ${HEALTH:-Normal} | Health: $HEALTH_PCT% | Current Capacity: ${CURRENT_CAP}mAh | Max Capacity: ${MAX_CAP}mAh | Design Capacity: ${DESIGN_CAP}mAh | Nominal Capacity: ${NOMINAL_CAP}mAh" >> "$LOG_FILE"
    echo "⚡ POWER: Temperature: ${TEMP}°C | Voltage: ${VOLTAGE}mV | Current: ${CHARGE_RATE} | Power Draw: ${POWER}W" >> "$LOG_FILE"
    echo "🔬 CELL ANALYSIS: Cell Voltages: ${CELL_VOLTAGES}mV | Balance Stats: ${CELL_STATS} | Qmax Values: ${QMAX_VALUES}mAh | Depth of Discharge: ${PRESENT_DOD}% | Resistance (Ra): ${WEIGHTED_RA}mΩ" >> "$LOG_FILE"
    echo "📈 LIFETIME STATISTICS: Estimated Life: ${LIFESPAN} | Total Runtime: ${TOTAL_RUNTIME} | Temp Range: ${MIN_TEMP_EVER}-${MAX_TEMP_EVER}°C (Avg:${AVG_TEMP_LIFETIME}°C) | Voltage History: ${MIN_VOLT_EVER}-${MAX_VOLT_EVER}mV | Current History: MaxCharge:${MAX_CHARGE_EVER}mA MaxDischarge:${MAX_DISCHARGE_EVER}mA | Last Calibration: Cycle ${LAST_CAL_CYCLE} | Daily SoC Range: ${DAILY_MIN_SOC}-${DAILY_MAX_SOC}%" >> "$LOG_FILE"
    echo "📅 BATTERY INFORMATION: Manufactured: ${MFG_DATE} | Serial Number: ${BATTERY_SERIAL}" >> "$LOG_FILE"
    echo "" >> "$LOG_FILE"
    
# Calculate current capacity percentage
if [ -n "$CURRENT_CAP" ] && [ -n "$MAX_CAP" ] && [ "$MAX_CAP" -gt 0 ] 2>/dev/null; then
    CURRENT_PCT_OF_MAX=$(echo "scale=1; ($CURRENT_CAP / $MAX_CAP) * 100" | bc)
else
    CURRENT_PCT_OF_MAX="N/A"
fi

NOTIFICATION="🔋 Battery Cycle Inc! Cycle: $LAST_CYCLE → $CURRENT_CYCLE

📊 STATUS
  Battery: $PERCENTAGE%
  Controller: $SOC% (SoC - internal estimate)
  Power Source: $CHARGING
  Charging Mode: $BATTERY_MODE${TIME_REMAINING:+
  Time Left: $TIME_REMAINING remaining}

🏥 HEALTH
  Condition: ${HEALTH:-Normal}
  Health: $HEALTH_PCT%
  Current: ${CURRENT_CAP}mAh (${CURRENT_PCT_OF_MAX}% of max)
  Max Capacity: ${MAX_CAP}mAh
  Design Cap: ${DESIGN_CAP}mAh

⚡ POWER
  Temperature: ${TEMP}°C
  Voltage: ${VOLTAGE}mV
  Amperage: ${CHARGE_RATE}
  Power Draw: ${POWER}W

🔬 CELL ANALYSIS
  Voltages: ${CELL_VOLTAGES}mV
  ${CELL_STATS}
  Qmax: ${QMAX_VALUES}mAh
  DOD: ${PRESENT_DOD}%
  Resistance: ${WEIGHTED_RA}mΩ

📈 LIFETIME STATS
  Lifespan: ${LIFESPAN}
  Total Runtime:  ${TOTAL_RUNTIME}
  Temp Range: ${MIN_TEMP_EVER}°C - ${MAX_TEMP_EVER}°C
  Avg Temp: ${AVG_TEMP_LIFETIME}°C
  Last Calibration: Cycle ${LAST_CAL_CYCLE}
  Today's Range  ${DAILY_MIN_SOC}% - ${DAILY_MAX_SOC}%

📅 BATTERY INFO
  Manufactured: ${MFG_DATE}
  Serial: ${BATTERY_SERIAL}"
    
    # Display notification with clickable buttons
    osascript <<OSASCRIPT_EOF
try
    set theResponse to button returned of (display dialog "$NOTIFICATION" buttons {"View Details", "Dismiss"} default button "Dismiss" with title "⚠️ Battery Cycle: $LAST_CYCLE → $CURRENT_CYCLE" with icon note giving up after 60)
    
    if theResponse is "View Details" then
        do shell script "open -a TextEdit '$LOG_FILE'"
    end if
on error
    -- Dialog timed out or was cancelled
end try
OSASCRIPT_EOF
fi

# Save current state (single file with all state)
cat > "$STATE_FILE" <<EOF
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# BATTERY MONITOR STATE (Auto-saved)
# Last Check: $(date '+%Y-%m-%d %H:%M:%S')
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

LAST_PCT="$CURRENT_PCT"
LAST_STATUS="$CURRENT_STATUS"
LAST_CYCLE="$CURRENT_CYCLE"
LAST_CHECK_TIME=$CURRENT_TIME
EOF

# ============================================
# ENHANCED HEALTH WARNINGS & ALERTS
# ============================================

# 1. Battery health warning (once per day)
if [ "$HEALTH_PCT" != "N/A" ]; then
    HEALTH_NUM=$(echo "$HEALTH_PCT" | cut -d. -f1)
    if [ -n "$HEALTH_NUM" ] && [ "$HEALTH_NUM" -lt 80 ] 2>/dev/null; then
        if should_notify "HEALTH_WARNING" 86400; then
            # Fetch additional context
            CYCLES=$(get_cycle_count)
            MAX_CYCLES=1000
            CYCLES_REMAINING=$((MAX_CYCLES - CYCLES))
            
            # Send notification first (quick)
            osascript -e "display notification \"Battery health at ${HEALTH_PCT}%. Service may be needed soon.\" with title \"⚠️ Battery Health Warning\" subtitle \"Cycle ${CYCLES}/${MAX_CYCLES}\" sound name \"Basso\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚠️ BATTERY HEALTH LOW

🏥 Current Health: ${HEALTH_PCT}%
🔄 Cycle Count: ${CYCLES} / ${MAX_CYCLES}
📉 Estimated Remaining: ${CYCLES_REMAINING} cycles

🔋 Battery Capacity:
   • Original: $(get_design_capacity)mAh
   • Current Max: $(get_max_capacity)mAh
   • Loss: $(($(get_design_capacity) - $(get_max_capacity)))mAh

💡 Recommendation:
Consider battery service at Apple Store or authorized service provider." buttons {"Apple Support", "View Log", "OK"} default button "OK" with title "Battery Service Recommended" with icon caution giving up after 30)

if theResponse is "Apple Support" then
    open location "https://support.apple.com/battery-service"
else if theResponse is "View Log" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Health Warning: $HEALTH_PCT%" >> "$LOG_FILE"
        fi
    fi
fi

# 2. Current temperature warning (>45°C)
if [ "$TEMP" != "N/A" ]; then
    TEMP_NUM=$(echo "$TEMP" | cut -d. -f1)
    if [ -n "$TEMP_NUM" ] && [ "$TEMP_NUM" -gt 45 ] 2>/dev/null; then
        if should_notify "HIGH_TEMP" 1800; then
            # Get lifetime max for context
            LIFETIME_MAX=${MAX_TEMP_EVER:-$(get_max_temp_ever)}
            
            # Send notification first (quick)
            osascript -e "display notification \"Battery temperature: ${TEMP}°C. Allow device to cool down.\" with title \"🌡️ High Temperature Alert\" subtitle \"Lifetime Max: ${LIFETIME_MAX}°C\" sound name \"Sosumi\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "🌡️ HIGH BATTERY TEMPERATURE

⚠️ Current: ${TEMP}°C (Safe range: 0-35°C)
📊 Lifetime Max: ${LIFETIME_MAX}°C

🔥 Heat Effects:
   • Accelerates battery aging
   • Reduces capacity over time
   • May trigger safety throttling

💡 Actions to Take:
   • Close intensive apps
   • Remove case if using one
   • Move to cooler location
   • Avoid charging until cooled" buttons {"View Log", "OK"} default button "OK" with title "High Temperature Alert" with icon stop giving up after 20)

if theResponse is "View Log" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🌡️ Temperature Warning: ${TEMP}°C" >> "$LOG_FILE"
        fi
    fi
fi

# 3. Lifetime maximum temperature warning (once per week)
MAX_TEMP_EVER=${MAX_TEMP_EVER:-$(get_max_temp_ever)}
if [ "$MAX_TEMP_EVER" != "N/A" ]; then
    MAX_TEMP_NUM=$(echo "$MAX_TEMP_EVER" | cut -d. -f1)
    if [ -n "$MAX_TEMP_NUM" ] && [ "$MAX_TEMP_NUM" -gt 45 ] 2>/dev/null; then
        if should_notify "MAX_TEMP_EVER" 604800; then  # 7 days
            # Send notification first (quick)
            osascript -e "display notification \"Battery exposed to ${MAX_TEMP_EVER}°C. High heat accelerates aging.\" with title \"⚠️ Heat Stress Detected\" subtitle \"Lifetime Maximum Temperature\" sound name \"Basso\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚠️ HEAT STRESS DETECTED

🌡️ Lifetime Max Temperature: ${MAX_TEMP_EVER}°C

⚠️ Impact:
   • High heat accelerates battery aging
   • Reduces maximum capacity over time
   • May shorten overall battery lifespan

💡 Prevention:
   • Avoid leaving in hot environments
   • Don't charge in direct sunlight
   • Remove case during intensive tasks
   • Keep device well-ventilated" buttons {"View Details", "OK"} default button "OK" with title "Heat Stress Detected" with icon caution giving up after 20)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Lifetime Max Temp: ${MAX_TEMP_EVER}°C" >> "$LOG_FILE"
        fi
    fi
fi

# 4. Cell voltage imbalance warning (>50mV)
CELL_VOLTAGES=${CELL_VOLTAGES:-$(get_cell_voltages)}
if [ "$CELL_VOLTAGES" != "N/A" ]; then
    IFS=',' read -ra CELLS <<< "$CELL_VOLTAGES"
    if [ ${#CELLS[@]} -gt 1 ]; then
        MIN_CELL=${CELLS[0]}
        MAX_CELL=${CELLS[0]}
        for cell in "${CELLS[@]}"; do
            if [ "$cell" -lt "$MIN_CELL" ] 2>/dev/null; then MIN_CELL=$cell; fi
            if [ "$cell" -gt "$MAX_CELL" ] 2>/dev/null; then MAX_CELL=$cell; fi
        done
        CELL_DIFF=$((MAX_CELL - MIN_CELL))
        
        if [ "$CELL_DIFF" -gt 50 ] 2>/dev/null; then
            if should_notify "CELL_IMBALANCE" 86400; then
                # Calculate severity
                SEVERITY="MODERATE"
                ICON="caution"
                SOUND="Basso"
                if [ "$CELL_DIFF" -gt 100 ]; then
                    SEVERITY="SEVERE"
                    ICON="stop"
                    SOUND="Sosumi"
                fi
                
                # Send notification first (quick)
                osascript -e "display notification \"Cell voltage difference: ${CELL_DIFF}mV. Calibration recommended.\" with title \"⚡ Cell Imbalance (${SEVERITY})\" subtitle \"Cells: ${CELL_VOLTAGES}mV\" sound name \"${SOUND}\"" 2>> "$LOG_FILE"
                
                # Then show detailed popup
                osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚡ CELL VOLTAGE IMBALANCE

🔋 Severity: ${SEVERITY} (${CELL_DIFF}mV difference)

📊 Cell Voltages:
   ${CELL_VOLTAGES}mV
   
   Min: ${MIN_CELL}mV
   Max: ${MAX_CELL}mV
   Difference: ${CELL_DIFF}mV

⚠️ What This Means:
   • Battery cells are out of balance
   • May cause inaccurate readings
   • Could reduce overall capacity

🔧 How to Fix (Calibration):
   1. Charge to 100% (leave plugged 2hrs)
   2. Use normally until < 5%
   3. Charge back to 100%
   4. Repeat if needed" buttons {"View Log", "OK"} default button "OK" with title "Cell Imbalance Detected" with icon ${ICON} giving up after 30)

if theResponse is "View Log" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Cell Imbalance: ${CELL_DIFF}mV (${CELL_VOLTAGES}mV)" >> "$LOG_FILE"
            fi
        fi
    fi
fi

# 5. Calibration reminder (>50 cycles since last cal)
NEEDS_CAL=$(needs_calibration)
if [[ "$NEEDS_CAL" == YES* ]]; then
    if should_notify "CALIBRATION_REMINDER" 2592000; then  # 30 days
        # Send notification first (quick)
        osascript -e "display notification \"$NEEDS_CAL\" with title \"🔧 Calibration Recommended\" subtitle \"Maintains accurate battery readings\" sound name \"Ping\"" 2>> "$LOG_FILE"
        
        # Then show detailed popup
        osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "🔧 CALIBRATION RECOMMENDED

$NEEDS_CAL

📋 How to Calibrate:
   1. Fully charge to 100%
   2. Keep plugged for 2 more hours
   3. Use normally until battery < 5%
   4. Fully charge back to 100%
   5. Keep plugged for 2 more hours

✅ Benefits:
   • Accurate battery percentage readings
   • Improved capacity estimates
   • Better power management

This process takes 1-2 charge cycles." buttons {"View Details", "OK"} default button "OK" with title "Calibration Recommended" with icon note giving up after 30)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔧 Calibration Reminder: $NEEDS_CAL" >> "$LOG_FILE"
    fi
fi

# 6. Low battery warning (≤20%)
if [ -n "$PERCENTAGE" ] && [ "$PERCENTAGE" -le 20 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
    if should_notify "LOW_BATTERY" 600; then
        # Send notification first (quick)
        osascript -e "display notification \"Battery at $PERCENTAGE%. Please charge soon.\" with title \"🔋 Low Battery\" subtitle \"Connect charger\" sound name \"Ping\"" 2>> "$LOG_FILE"
        
        # Then show detailed popup
        osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "🔋 LOW BATTERY

⚠️ Battery Level: $PERCENTAGE%
${TIME_REMAINING:+⏱️ Time Remaining: $TIME_REMAINING}
⚡ Power Draw: ${POWER}W

💡 Recommendation:
Connect your charger soon to avoid unexpected shutdown.

Current battery health: ${HEALTH_PCT}%" buttons {"View Details", "OK"} default button "OK" with title "Low Battery Warning" with icon caution giving up after 20)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔋 Low Battery: $PERCENTAGE%" >> "$LOG_FILE"
    fi
fi

# 6. Good level warning (>=80%)
if [ -n "$PERCENTAGE" ] && [ "$PERCENTAGE" -ge 80 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
    if should_notify "GOOD_BATTERY" 1800; then
        # Send notification first (quick)
        osascript -e "display notification \"Battery at $PERCENTAGE%. Looking good!\" with title \"🔋 Battery Healthy\" subtitle \"Plenty of charge remaining\" sound name \"Ping\"" 2>> "$LOG_FILE"
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔋 Good Battery: $PERCENTAGE%" >> "$LOG_FILE"
    fi
fi

# 7. Critical battery warning (≤10%)
if [ -n "$PERCENTAGE" ] && [ "$PERCENTAGE" -le 10 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
    # Send notification first (quick)
    osascript -e "display notification \"Battery critically low at $PERCENTAGE%! Connect charger immediately.\" with title \"⚠️ CRITICAL: Charge Now!\" subtitle \"System may shut down soon\" sound name \"Sosumi\"" 2>> "$LOG_FILE"
    
    # Then show detailed popup
    osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚠️ CRITICAL BATTERY LEVEL

🔴 Battery: $PERCENTAGE%
${TIME_REMAINING:+⏱️ Estimated: $TIME_REMAINING}

⚠️ WARNING:
System may shut down at any moment without further warning.

🔌 ACTION REQUIRED:
Connect charger immediately and save all work!" buttons {"View Details", "OK"} default button "OK" with title "CRITICAL: Charge Now!" with icon stop giving up after 15)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔴 Critical Battery: $PERCENTAGE%" >> "$LOG_FILE"
fi

# 8. Fully charged notification (100%)
if pmset -g batt | grep -q "charged" && [ "$CHARGING" == "AC Power" ]; then
    if should_notify "FULLY_CHARGED" 3600; then
        osascript <<OSASCRIPT_EOF
display notification "Unplug to preserve battery health" with title "✅ Battery Fully Charged (100%)" subtitle "Cycle ${CURRENT_CYCLE} | Health ${HEALTH_PCT}%" sound name "Hero"
OSASCRIPT_EOF
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ✅ Fully charged: ${PERCENTAGE}% | Cycle: ${CURRENT_CYCLE} | Health: ${HEALTH_PCT}%" >> "$LOG_FILE"
    fi
fi

# 8.5. Battery crossing 50% threshold (going down)
if [ -n "$LAST_PCT" ] && [ -n "$CURRENT_PCT" ]; then
    if [ "$LAST_PCT" -gt 50 ] 2>/dev/null && [ "$CURRENT_PCT" -le 50 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
        if should_notify "CROSS_50_DOWN" 3600; then
            osascript <<OSASCRIPT_EOF
display notification "Battery dropped to ${CURRENT_PCT}%. Consider charging soon." with title "🔋 Battery at 50%" subtitle "Cycle ${CURRENT_CYCLE} | Health ${HEALTH_PCT}%" sound name "Ping"
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📉 Battery crossed 50% going down: ${LAST_PCT}% → ${CURRENT_PCT}%" >> "$LOG_FILE"
        fi
    fi
fi

# 8.6. Battery crossing 50% threshold (going up)
if [ -n "$LAST_PCT" ] && [ -n "$CURRENT_PCT" ]; then
    if [ "$LAST_PCT" -lt 50 ] 2>/dev/null && [ "$CURRENT_PCT" -ge 50 ] 2>/dev/null && [ "$CHARGING" == "AC Power" ]; then
        if should_notify "CROSS_50_UP" 3600; then
            osascript <<OSASCRIPT_EOF
display notification "Battery charged to ${CURRENT_PCT}%. Halfway there!" with title "🔋 Battery at 50%" subtitle "Cycle ${CURRENT_CYCLE} | Health ${HEALTH_PCT}%" sound name "Hero"
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📈 Battery crossed 50% going up: ${LAST_PCT}% → ${CURRENT_PCT}%" >> "$LOG_FILE"
        fi
    fi
fi

# 8.7. Battery crossing 80% threshold (going down)
if [ -n "$LAST_PCT" ] && [ -n "$CURRENT_PCT" ]; then
    if [ "$LAST_PCT" -gt 80 ] 2>/dev/null && [ "$CURRENT_PCT" -le 80 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
        if should_notify "CROSS_80_DOWN" 3600; then
            osascript <<OSASCRIPT_EOF
display notification "Battery at ${CURRENT_PCT}%. Still good capacity remaining." with title "🔋 Battery at 80%" subtitle "Cycle ${CURRENT_CYCLE} | Health ${HEALTH_PCT}%" sound name "Ping"
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📉 Battery crossed 80% going down: ${LAST_PCT}% → ${CURRENT_PCT}%" >> "$LOG_FILE"
        fi
    fi
fi

# 8.8. Battery crossing 80% threshold (going up)
if [ -n "$LAST_PCT" ] && [ -n "$CURRENT_PCT" ]; then
    if [ "$LAST_PCT" -lt 80 ] 2>/dev/null && [ "$CURRENT_PCT" -ge 80 ] 2>/dev/null && [ "$CHARGING" == "AC Power" ]; then
        if should_notify "CROSS_80_UP" 3600; then
            osascript <<OSASCRIPT_EOF
display notification "Battery charged to ${CURRENT_PCT}%. Almost full!" with title "🔋 Battery at 80%" subtitle "Cycle ${CURRENT_CYCLE} | Health ${HEALTH_PCT}%" sound name "Hero"
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 📈 Battery crossed 80% going up: ${LAST_PCT}% → ${CURRENT_PCT}%" >> "$LOG_FILE"
        fi
    fi
fi

# 9. High power consumption warning (>15W)
if [ "$POWER" != "N/A" ]; then
    POWER_NUM=$(echo "$POWER" | cut -d. -f1)
    if [ -n "$POWER_NUM" ] && [ "$POWER_NUM" -gt 15 ] 2>/dev/null && [ "$CHARGING" == "Battery Power" ]; then
        if should_notify "HIGH_POWER" 1800; then  # 30 minutes
            # Send notification first (quick)
            osascript -e "display notification \"High power draw: ${POWER}W. Battery draining rapidly.\" with title \"⚡ High Power Consumption\" subtitle \"Check Activity Monitor\" sound name \"Basso\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚡ HIGH POWER CONSUMPTION

🔋 Current Draw: ${POWER}W
📊 Battery: $PERCENTAGE%
⚠️ Draining faster than normal

💡 Suggestions:
   • Check Activity Monitor for heavy apps
   • Reduce screen brightness
   • Close unused applications
   • Consider plugging in charger

⏱️ At this rate:
Battery will drain significantly faster than expected." buttons {"Activity Monitor", "OK"} default button "OK" with title "High Power Usage Alert" with icon caution giving up after 25)

if theResponse is "Activity Monitor" then
    do shell script "open -a 'Activity Monitor'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚡ High Power: ${POWER}W" >> "$LOG_FILE"
        fi
    fi
fi

# 10. Battery not charging (AC but amperage ~0)
if [ "$CHARGING" == "AC Power" ]; then
    AMPERAGE_NUM=$(echo "$AMPERAGE" | grep -Eo '^-?[0-9]+' || echo "0")
    
    if [ -n "$AMPERAGE_NUM" ] && [ "$AMPERAGE_NUM" -lt 100 ] 2>/dev/null && \
       [ "$AMPERAGE_NUM" -gt -100 ] 2>/dev/null && [ "$PERCENTAGE" -lt 95 ] 2>/dev/null; then
        if should_notify "NOT_CHARGING" 1800; then  # 30 minutes
            # Send notification first (quick)
            osascript -e "display notification \"Charger connected but battery not charging (${AMPERAGE_NUM}mA).\" with title \"🔌 Charging Issue\" subtitle \"Check connections\" sound name \"Basso\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "🔌 CHARGER CONNECTED BUT NOT CHARGING

📊 Status:
   • Power: AC Connected
   • Battery: ${PERCENTAGE}%
   • Current: ${AMPERAGE_NUM}mA (too low)
   • Temperature: ${TEMP}°C

⚠️ Possible Causes:
   • Faulty charger/cable
   • Optimized charging hold
   • Battery temperature too high/low
   • Power adapter insufficient

💡 Try:
   • Check cable connections
   • Use different power adapter
   • Check if temp is in safe range (10-35°C)
   • Restart if issue persists" buttons {"View Details", "OK"} default button "OK" with title "Charging Issue Detected" with icon caution giving up after 30)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🔌 Not charging: ${PERCENTAGE}% | ${AMPERAGE_NUM}mA | Temp: ${TEMP}°C" >> "$LOG_FILE"
        fi
    fi
fi

# 11. Rapid battery drain (>10% per 30 minutes)
if [ "$CHARGING" == "Battery Power" ] && [ -n "$LAST_PCT" ] && [ "$LAST_PCT" != "" ]; then
    PCT_CHANGE=$((CURRENT_PCT - LAST_PCT))
    TIME_DIFF=$((CURRENT_TIME - LAST_CHECK_TIME))
    
    if [ "$TIME_DIFF" -gt 0 ] 2>/dev/null; then
        DRAIN_RATE_30MIN=$(echo "scale=1; ($PCT_CHANGE * 1800) / $TIME_DIFF" | bc 2>/dev/null || echo "0")
        DRAIN_RATE_NUM=$(echo "$DRAIN_RATE_30MIN" | cut -d. -f1 2>/dev/null || echo "0")
        
        if [ -n "$DRAIN_RATE_NUM" ] && [ "$DRAIN_RATE_NUM" -lt -10 ] 2>/dev/null; then
            if should_notify "RAPID_DRAIN" 3600; then  # 1 hour
                ESTIMATED_TIME=$((CURRENT_PCT * 30 / (-1 * DRAIN_RATE_NUM)))
                
                # Send notification first (quick)
                osascript -e "display notification \"Draining ${DRAIN_RATE_30MIN#-}% per 30min. ~${ESTIMATED_TIME}min remaining.\" with title \"⚠️ Rapid Battery Drain\" subtitle \"Power: ${POWER}W\" sound name \"Basso\"" 2>> "$LOG_FILE"
                
                # Then show detailed popup
                osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "⚠️ RAPID BATTERY DRAIN DETECTED

📉 Drain Rate: ${DRAIN_RATE_30MIN#-}% per 30 minutes
🔋 Current: ${CURRENT_PCT}%
⏱️ Estimated Time: ~${ESTIMATED_TIME} minutes remaining

⚡ Current Power: ${POWER}W
📊 ${CHARGE_RATE}

💡 Actions to Take:
   • Check Activity Monitor for CPU hogs
   • Reduce screen brightness
   • Close unused applications
   • Disable Bluetooth if not needed
   • Consider charging soon

This drain rate is significantly higher than normal." buttons {"Activity Monitor", "OK"} default button "OK" with title "Rapid Battery Drain" with icon stop giving up after 25)

if theResponse is "Activity Monitor" then
    do shell script "open -a 'Activity Monitor'"
end if
OSASCRIPT_EOF
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Rapid drain: ${DRAIN_RATE_30MIN}%/30min | Power: ${POWER}W" >> "$LOG_FILE"
            fi
        fi
    fi
fi

# 12. Slow charging warning (<500mA)
if [ "$CHARGING" == "AC Power" ] && [ "$PERCENTAGE" -lt 95 ] 2>/dev/null; then
    AMPERAGE_NUM=$(echo "$AMPERAGE" | grep -Eo '^-?[0-9]+' || echo "0")
    
    if [ -n "$AMPERAGE_NUM" ] && [ "$AMPERAGE_NUM" -gt 0 ] 2>/dev/null && \
       [ "$AMPERAGE_NUM" -lt 500 ] 2>/dev/null; then
        if should_notify "SLOW_CHARGING" 3600; then  # 1 hour
            # Send notification first (quick)
            osascript -e "display notification \"Charging slowly at ${AMPERAGE_NUM}mA. Use higher wattage charger.\" with title \"🐌 Slow Charging\" subtitle \"Expected: >1000mA\" sound name \"Ping\"" 2>> "$LOG_FILE"
            
            # Then show detailed popup
            osascript <<OSASCRIPT_EOF
set theResponse to button returned of (display dialog "🐌 SLOW CHARGING DETECTED

⚡ Charging Rate: ${AMPERAGE_NUM}mA
   Expected: >1000mA for normal charging
🔋 Battery: ${PERCENTAGE}%
🌡️ Temperature: ${TEMP}°C

⚠️ Possible Causes:
   • Weak power adapter (use 60W+ for MacBook)
   • Long or damaged cable
   • USB-C port instead of MagSafe
   • Background tasks consuming power
   • Battery temperature regulation

💡 To Fix:
   • Use original Apple charger
   • Try different power outlet
   • Close intensive applications
   • Let battery cool if temperature high
   • Check cable for damage" buttons {"View Details", "OK"} default button "OK" with title "Slow Charging Alert" with icon caution giving up after 30)

if theResponse is "View Details" then
    do shell script "open -a TextEdit '$LOG_FILE'"
end if
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🐌 Slow charging: ${AMPERAGE_NUM}mA | Temp: ${TEMP}°C" >> "$LOG_FILE"
        fi
    fi
fi

# 13. Battery kept at 100% too long (>8 hours)
if [ "$PERCENTAGE" -eq 100 ] 2>/dev/null && [ "$CHARGING" == "AC Power" ]; then
    LAST_100_TIME_FILE="$HOME/battery/.last_100_time"
    
    if [ ! -f "$LAST_100_TIME_FILE" ]; then
        echo "$CURRENT_TIME" > "$LAST_100_TIME_FILE"
    else
        LAST_100_TIME=$(cat "$LAST_100_TIME_FILE")
        TIME_AT_100=$((CURRENT_TIME - LAST_100_TIME))
        
        if [ "$TIME_AT_100" -gt 28800 ] 2>/dev/null; then
            if should_notify "EXTENDED_100" 86400; then  # Once per day
                HOURS_AT_100=$((TIME_AT_100 / 3600))
                
                osascript <<OSASCRIPT_EOF
display notification "Battery has been at 100% for ${HOURS_AT_100} hours. Consider unplugging to preserve battery health." with title "🔋 Battery Health Tip" subtitle "Extended Time at Full Charge" sound name "Ping"
OSASCRIPT_EOF
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ℹ️ Battery at 100% for ${HOURS_AT_100}h" >> "$LOG_FILE"
            fi
        fi
    fi
else
    rm -f "$HOME/battery/.last_100_time" 2>/dev/null
fi

# 14. Charging in hot environment (>35°C while charging)
if [ "$CHARGING" == "AC Power" ] && [ "$TEMP" != "N/A" ]; then
    TEMP_NUM=$(echo "$TEMP" | cut -d. -f1)
    AMPERAGE_NUM=$(echo "$AMPERAGE" | grep -Eo '^-?[0-9]+' || echo "0")
    
    if [ -n "$TEMP_NUM" ] && [ "$TEMP_NUM" -gt 35 ] 2>/dev/null && \
       [ "$AMPERAGE_NUM" -gt 100 ] 2>/dev/null; then
        if should_notify "HOT_CHARGING" 3600; then  # 1 hour
            osascript <<OSASCRIPT_EOF
display notification "Charging at ${TEMP}°C accelerates battery aging. Consider cooling down before charging." with title "🌡️ Charging Temperature Warning" subtitle "Temp: ${TEMP}°C (recommended: <30°C)" sound name "Basso"
OSASCRIPT_EOF
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🌡️ Hot charging: ${TEMP}°C | ${AMPERAGE_NUM}mA" >> "$LOG_FILE"
        fi
    fi
fi

# ============================================
# CLEANUP OLD LOGS (keep last 10000 lines)
# ============================================
if [ -f "$LOG_FILE" ]; then
    LINE_COUNT=$(wc -l < "$LOG_FILE")
    if [ "$LINE_COUNT" -gt 10000 ]; then
        if tail -10000 "$LOG_FILE" > "${LOG_FILE}.tmp" 2>/dev/null; then
            mv "${LOG_FILE}.tmp" "$LOG_FILE"
        else
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⚠️ Log rotation failed" >> "$LOG_FILE" 2>/dev/null
        fi
    fi
fi

# ============================================
# EXECUTION SUMMARY
# ============================================
EXECUTION_TIME=$(($(date +%s) - CURRENT_TIME))
log_info "Execution completed in ${EXECUTION_TIME}s | Battery: ${CURRENT_PCT}% | Status: ${CURRENT_STATUS}"

exit 0