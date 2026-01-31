
# 4. Run installer
bash ~/battery/install_battery_monitor.sh

# 5. Verify it's running
bash ~/battery/battery_manager.sh status

# View recent logs
~/battery/battery_manager.sh logs

# Check for errors
~/battery/battery_manager.sh errors

# Test the script manually
~/battery/battery_manager.sh test

# Restart the monitor
~/battery/battery_manager.sh restart

# Stop the monitor
~/battery/battery_manager.sh stop

# Start the monitor
~/battery/battery_manager.sh start