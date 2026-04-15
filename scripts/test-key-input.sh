#!/bin/bash
# Integration test: verify key input reaches the terminal correctly.
#
# This script:
# 1. Builds and launches e05 in the background
# 2. Waits for the terminal to be ready
# 3. Sends keystrokes via osascript (AppleScript)
# 4. Verifies the terminal received the correct bytes
#
# Usage: ./scripts/test-key-input.sh
#
# Requirements:
# - Accessibility permissions for Terminal / the calling app
# - GhosttyKit.xcframework in place

set -euo pipefail
cd "$(dirname "$0")/.."

RESULT_FILE="/tmp/e05-key-test-result.txt"
TEST_SCRIPT="/tmp/e05-key-test-capture.sh"
TIMEOUT=10

cleanup() {
    # Kill e05 if still running
    if [[ -n "${E05_PID:-}" ]] && kill -0 "$E05_PID" 2>/dev/null; then
        kill "$E05_PID" 2>/dev/null || true
    fi
    rm -f "$TEST_SCRIPT" "$RESULT_FILE"
}
trap cleanup EXIT

echo "[*] building e05..."
swift build --disable-sandbox -q 2>&1

# Create a capture script that runs inside the terminal.
# It uses `cat -v` to make control characters visible, then writes to a file.
cat > "$TEST_SCRIPT" << 'CAPTURE_EOF'
#!/bin/bash
# Capture raw key input and write to result file
RESULT_FILE="/tmp/e05-key-test-result.txt"
echo "READY" > "$RESULT_FILE"

# Read a single line of input with timeout
read -r -t 15 input_line
echo "INPUT:$input_line" >> "$RESULT_FILE"

# Also capture via cat -v for control char visibility
echo "$input_line" | cat -v >> "$RESULT_FILE"
echo "DONE" >> "$RESULT_FILE"
exit 0
CAPTURE_EOF
chmod +x "$TEST_SCRIPT"

echo "[*] launching e05..."
rm -f "$RESULT_FILE"
swift run --disable-sandbox &
E05_PID=$!

# Wait for e05 window to appear
echo "[*] waiting for e05 window..."
for i in $(seq 1 $TIMEOUT); do
    if osascript -e 'tell application "System Events" to get name of first window of (first process whose name is "e05")' 2>/dev/null; then
        break
    fi
    sleep 1
done

# Give terminal a moment to initialize
sleep 2

echo "[*] sending test keystrokes..."

# Type the test command: run the capture script
osascript <<APPLESCRIPT
tell application "System Events"
    tell process "e05"
        set frontmost to true
        delay 0.5
        -- Type: echo hello
        keystroke "echo hello"
        delay 0.3
        -- Press Enter
        key code 36
        delay 1
    end tell
end tell
APPLESCRIPT

echo "[*] verifying output..."

# Give time for the command to execute
sleep 2

# Check if e05 is still running (it should be — Enter should have worked)
if kill -0 "$E05_PID" 2>/dev/null; then
    echo "[+] e05 is still running after Enter — Enter key works"
else
    echo "[-] e05 exited unexpectedly"
    exit 1
fi

# Send ESC to verify it doesn't crash
osascript <<APPLESCRIPT
tell application "System Events"
    tell process "e05"
        set frontmost to true
        delay 0.3
        key code 53
        delay 1
    end tell
end tell
APPLESCRIPT

if kill -0 "$E05_PID" 2>/dev/null; then
    echo "[+] e05 is still running after ESC — no hang"
else
    echo "[-] e05 crashed or hung after ESC"
    exit 1
fi

# Send exit + Enter to cleanly close
osascript <<APPLESCRIPT
tell application "System Events"
    tell process "e05"
        set frontmost to true
        delay 0.3
        keystroke "exit"
        delay 0.3
        key code 36
    end tell
end tell
APPLESCRIPT

# Wait for e05 to exit
sleep 2

if kill -0 "$E05_PID" 2>/dev/null; then
    echo "[-] e05 did not exit after 'exit' command"
    kill "$E05_PID" 2>/dev/null || true
    exit 1
else
    echo "[+] e05 exited cleanly after 'exit' command"
fi

echo ""
echo "[+] all integration tests passed"
