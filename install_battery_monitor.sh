#install_battery_monitor.sh
#!/bin/bash

# ============================================
# BATTERY MONITOR LAUNCHAGENT INSTALLER
# ============================================

echo "🔋 Battery Monitor LaunchAgent Installer"
echo "========================================"
echo ""

# Get current username
USERNAME=$(whoami)
HOME_DIR="$HOME"

# Define paths
PLIST_SOURCE="$HOME_DIR/battery/com.battery.monitor.optimized.plist"
PLIST_DEST="$HOME_DIR/Library/LaunchAgents/com.battery.monitor.optimized.plist"
SCRIPT_PATH="$HOME_DIR/battery/battery_monitor.sh"

# Step 1: Check if battery directory exists
if [ ! -d "$HOME_DIR/battery" ]; then
    echo "❌ Error: Battery directory not found at $HOME_DIR/battery"
    echo "   Please create it first: mkdir -p ~/battery"
    exit 1
fi

# Step 2: Check if battery_monitor.sh exists
if [ ! -f "$SCRIPT_PATH" ]; then
    echo "❌ Error: Battery monitor script not found at $SCRIPT_PATH"
    echo "   Please place battery_monitor.sh in ~/battery/ first"
    exit 1
fi

# Step 3: Make sure the script is executable
chmod +x "$SCRIPT_PATH"
echo "✅ Made battery_monitor.sh executable"

# Step 4: Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME_DIR/Library/LaunchAgents"
echo "✅ LaunchAgents directory ready"

# Step 5: Create plist file directly
cat > "$PLIST_DEST" <<'PLIST_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.battery.monitor.optimized</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>HOME_PLACEHOLDER/battery/battery_monitor.sh</string>
    </array>
    
    <key>StartInterval</key>
    <integer>60</integer>
    
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration/com.apple.PowerManagement.plist</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <false/>
    
    <key>Nice</key>
    <integer>10</integer>
    
    <key>StandardOutPath</key>
    <string>HOME_PLACEHOLDER/battery/.battery_launchd_stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>HOME_PLACEHOLDER/battery/.battery_launchd_stderr.log</string>
    
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>256</integer>
    </dict>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    
    <key>ProcessType</key>
    <string>Background</string>
    
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
PLIST_EOF

# Replace HOME_PLACEHOLDER with actual path
if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "s#HOME_PLACEHOLDER#${HOME_DIR}#g" "$PLIST_DEST"
else
    sed -i '' "s#HOME_PLACEHOLDER#${HOME_DIR}#g" "$PLIST_DEST"
fi
echo "✅ Created plist file: $PLIST_DEST"

# Step 6: Set correct permissions
chmod 644 "$PLIST_DEST"
echo "✅ Set correct permissions on plist file"

# Step 7: Unload existing LaunchAgent (if running)
if launchctl list | grep -q "com.battery.monitor.optimized"; then
    launchctl unload "$PLIST_DEST" 2>/dev/null
    echo "✅ Unloaded existing LaunchAgent"
fi

# Step 8: Load the LaunchAgent
launchctl load "$PLIST_DEST"
if [ $? -eq 0 ]; then
    echo "✅ Successfully loaded LaunchAgent"
else
    echo "❌ Failed to load LaunchAgent"
    exit 1
fi

# Step 9: Verify it's running
sleep 2
if launchctl list | grep -q "com.battery.monitor.optimized"; then
    echo "✅ LaunchAgent is active and running"
else
    echo "⚠️  LaunchAgent loaded but not showing in list (this is sometimes normal)"
fi

# Step 10: Show status
echo ""
echo "========================================"
echo "✅ Installation Complete!"
echo "========================================"
echo ""
echo "📊 Battery monitor will now run automatically:"
echo "   • Every 1 minute (exits instantly if no changes)"
echo "   • When power state changes"
echo "   • At login"
echo ""
echo "📁 Files created:"
echo "   • LaunchAgent: $PLIST_DEST"
echo "   • Logs: ~/battery/.battery_monitor.log"
echo "   • LaunchD logs: ~/battery/.battery_launchd_stdout.log"
echo ""
echo "🛠️  Useful commands:"
echo "   • Check status:  launchctl list | grep battery"
echo "   • View logs:     tail -f ~/battery/.battery_monitor.log"
echo "   • Stop:          launchctl unload $PLIST_DEST"
echo "   • Start:         launchctl load $PLIST_DEST"
echo "   • Restart:       launchctl unload $PLIST_DEST && launchctl load $PLIST_DEST"
echo ""
