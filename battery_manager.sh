#battery_manager.sh
#!/bin/bash

# ============================================
# BATTERY MONITOR MANAGER
# ============================================

PLIST_PATH="$HOME/Library/LaunchAgents/com.battery.monitor.optimized.plist"
LOG_FILE="$HOME/battery/.battery_monitor.log"
LAUNCHD_LOG="$HOME/battery/.battery_launchd_stderr.log"

show_help() {
    echo "🔋 Battery Monitor Manager"
    echo "=========================="
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  status    - Check if battery monitor is running"
    echo "  start     - Start the battery monitor"
    echo "  stop      - Stop the battery monitor"
    echo "  restart   - Restart the battery monitor"
    echo "  logs      - Show recent battery log entries"
    echo "  errors    - Show LaunchAgent error log"
    echo "  install   - Install/reinstall the LaunchAgent"
    echo "  uninstall - Completely remove the LaunchAgent"
    echo "  test      - Run the monitor script once manually"
    echo ""
}

check_status() {
    if launchctl list | grep -q "com.battery.monitor.optimized"; then
        echo "✅ Battery monitor is RUNNING"
        launchctl list | grep "com.battery.monitor.optimized"
        return 0
    else
        echo "❌ Battery monitor is NOT running"
        return 1
    fi
}

start_monitor() {
    if [ ! -f "$PLIST_PATH" ]; then
        echo "❌ LaunchAgent plist not found. Run: $0 install"
        return 1
    fi
    
    launchctl load "$PLIST_PATH"
    if [ $? -eq 0 ]; then
        echo "✅ Battery monitor started"
    else
        echo "❌ Failed to start battery monitor"
    fi
}

stop_monitor() {
    launchctl unload "$PLIST_PATH" 2>/dev/null
    if [ $? -eq 0 ]; then
        echo "✅ Battery monitor stopped"
    else
        echo "⚠️  Battery monitor was not running"
    fi
}

restart_monitor() {
    echo "🔄 Restarting battery monitor..."
    stop_monitor
    sleep 1
    start_monitor
}

show_logs() {
    echo "📊 BATTERY LOGS"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if [ -f "$LOG_FILE" ]; then
        echo ""
        echo "📝 Event Log (Last 20 entries):"
        echo "────────────────────────────────────────"
        tail -20 "$LOG_FILE"
    else
        echo "❌ No event log found at $LOG_FILE"
    fi
    
    echo ""
    echo "🔧 LaunchAgent Output (Last 20 entries):"
    echo "────────────────────────────────────────"
    if [ -f "$HOME/battery/.battery_launchd_stdout.log" ]; then
        tail -20 "$HOME/battery/.battery_launchd_stdout.log"
    else
        echo "No stdout log yet"
    fi
    
    echo ""
    echo "⚠️  LaunchAgent Errors (Last 10 entries):"
    echo "────────────────────────────────────────"
    if [ -f "$LAUNCHD_LOG" ]; then
        tail -10 "$LAUNCHD_LOG"
    else
        echo "No errors logged"
    fi
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

show_errors() {
    if [ -f "$LAUNCHD_LOG" ]; then
        echo "⚠️  LaunchAgent Error Log (Last 50 entries):"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        tail -50 "$LAUNCHD_LOG"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    else
        echo "✅ No errors logged (or log file doesn't exist yet)"
    fi
}

uninstall() {
    echo "🗑️  Uninstalling battery monitor..."
    
    # Stop the agent
    stop_monitor
    
    # Remove plist
    if [ -f "$PLIST_PATH" ]; then
        rm "$PLIST_PATH"
        echo "✅ Removed LaunchAgent plist"
    fi
    
    echo "✅ Uninstallation complete"
    echo ""
    echo "Note: Log files in ~/battery/ were NOT deleted"
    echo "To remove them: rm -rf ~/battery/"
}

test_run() {
    if [ ! -f "$HOME/battery/battery_monitor.sh" ]; then
        echo "❌ battery_monitor.sh not found!"
        exit 1
    fi
    echo "🧪 Running battery monitor script once..."
    echo "=========================================="
    bash "$HOME/battery/battery_monitor.sh"
    echo ""
    echo "✅ Test run complete. Check output above for any errors."
}

# Main script logic
case "${1:-}" in
    status)
        check_status
        ;;
    start)
        start_monitor
        ;;
    stop)
        stop_monitor
        ;;
    restart)
        restart_monitor
        ;;
    logs)
        show_logs
        ;;
    errors)
        show_errors
        ;;
    uninstall)
        uninstall
        ;;
    test)
        test_run
        ;;
    install)
        echo "Please run: bash ~/battery/install_battery_monitor.sh"
        ;;
    help|--help|-h|"")
        show_help
        ;;
    *)
        echo "❌ Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac
