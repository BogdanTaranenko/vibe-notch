#!/usr/bin/env python3
"""
Vibe Notch status line bridge
- Forwards Claude Code's plan usage limits (rate_limits) to the app's socket
- Then runs the status line the user had before, with the same input, and
  prints whatever it prints — so opting in changes nothing they can see
"""
import json
import os
import socket
import sys

SOCKET_PATH = "/tmp/claude-island.sock"
SEND_TIMEOUT_SECONDS = 0.5
PASSTHROUGH_TIMEOUT_SECONDS = 10
PASSTHROUGH_FILE = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "claude-island-statusline.json"
)

# Set on the passthrough's environment. Two apps that each wrap "the previous
# status line" can end up wrapping each other; seeing our own marker means we
# are being run from inside ourselves, and the chain stops here.
RECURSION_MARKER = "VIBE_NOTCH_STATUSLINE"


def send_rate_limits(data):
    """Fire and forget. The status line must never wait on the app."""
    limits = data.get("rate_limits")
    if not isinstance(limits, dict) or not limits:
        return

    report = {
        "session_id": data.get("session_id", "unknown"),
        "cwd": data.get("cwd", ""),
        "event": "StatusLine",
        "status": "rate_limits",
        "rate_limits": limits,
    }
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.settimeout(SEND_TIMEOUT_SECONDS)
        sock.connect(SOCKET_PATH)
        sock.sendall(json.dumps(report).encode())
        sock.close()
    except (socket.error, OSError):
        pass


def passthrough_command():
    try:
        with open(PASSTHROUGH_FILE, "r", encoding="utf-8") as handle:
            line = json.load(handle).get("statusLine")
    except (OSError, ValueError, AttributeError):
        return None

    if not isinstance(line, dict) or line.get("type") != "command":
        return None
    command = line.get("command")
    if not isinstance(command, str) or not command.strip():
        return None
    return command


def run_passthrough(raw_input):
    command = passthrough_command()
    if not command:
        return

    # Imported here for the same reason the hook script does: loading
    # subprocess can fail on interpreters macOS refuses to dlopen, and that
    # must cost the passthrough, not the usage report already sent.
    try:
        import subprocess

        env = dict(os.environ)
        env[RECURSION_MARKER] = "1"
        result = subprocess.run(
            ["/bin/sh", "-c", command],
            input=raw_input,
            stdout=subprocess.PIPE,
            env=env,
            timeout=PASSTHROUGH_TIMEOUT_SECONDS,
        )
        sys.stdout.buffer.write(result.stdout)
        sys.stdout.flush()
    except Exception:
        pass


def main():
    if os.environ.get(RECURSION_MARKER):
        sys.exit(0)

    raw_input = sys.stdin.buffer.read()

    try:
        data = json.loads(raw_input)
    except ValueError:
        data = None

    if isinstance(data, dict):
        send_rate_limits(data)

    run_passthrough(raw_input)


if __name__ == "__main__":
    main()
