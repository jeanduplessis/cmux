# Notifications

cmux provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

## Quick Start

```bash
# Send a notification (if cmux is available)
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v cmux &>/dev/null && cmux notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `cmux` CLI is available before using it:

```bash
# Shell
if command -v cmux &>/dev/null; then
    cmux notify --title "Hello"
fi

# One-liner with fallback
command -v cmux &>/dev/null && cmux notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("cmux"):
        subprocess.run(["cmux", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
cmux notify --title "Build Complete"

# With subtitle and body
cmux notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Notify specific tab/panel
cmux notify --title "Done" --tab 0 --panel 1
```

## Integration Examples

### Claude Code Hooks

Add to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v cmux &>/dev/null && cmux notify --title 'Claude Code' --body 'Waiting for input' || osascript -e 'display notification \"Waiting for input\" with title \"Claude Code\"'"
          }
        ]
      },
      {
        "matcher": "permission_prompt",
        "hooks": [
          {
            "type": "command",
            "command": "command -v cmux &>/dev/null && cmux notify --title 'Claude Code' --subtitle 'Permission' --body 'Approval needed' || osascript -e 'display notification \"Approval needed\" with title \"Claude Code\"'"
          }
        ]
      }
    ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v cmux &>/dev/null && cmux notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v cmux &>/dev/null && cmux notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### Kilo Code (Rich Integration)

cmux ships a full-featured Kilo Code plugin that provides sidebar status, targeted
notifications, OSC suppression, and agent PID tracking — matching the Claude Code
integration level.

**Install:**

```bash
# Copy from this repo
cp plugins/kilo/cmux-integration.ts ~/.config/kilo/plugins/cmux-integration.ts

# Or symlink for automatic updates
ln -s /path/to/cmux/plugins/kilo/cmux-integration.ts ~/.config/kilo/plugins/cmux-integration.ts
```

**What it does:**

| Event | cmux Behavior |
|-------|---------------|
| Plugin init | Registers agent PID (enables OSC suppression), sets status to Idle |
| `tool.execute.before` | Clears notifications, sets status to "Running" (or verbose tool description) |
| `message.part.updated` | Sets status to "Running" when agent starts responding |
| `permission.asked` | Sends notification, sets status to "Needs input" |
| `permission.replied` | Clears notifications, sets status to "Running" |
| `session.idle` | Sends completion notification, sets status to "Idle" |
| `session.error` | Sends error notification, sets status to "Error" |
| Process exit | Clears status, agent PID, and notifications |

**Environment variables:**

| Variable | Description |
|----------|-------------|
| `CMUX_KILO_VERBOSE` | Set to any value to show verbose tool descriptions in sidebar status (e.g., "Editing main.ts" instead of "Running") |

The plugin auto-detects cmux via `CMUX_SOCKET_PATH` and is a no-op outside cmux terminals.

### OpenCode Plugin

Create `~/.config/opencode/plugins/cmux-notify.js`:

```javascript
export const CmuxNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v cmux && cmux notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

For a richer OpenCode integration (sidebar status, PID tracking), adapt the
Kilo Code plugin above — the plugin APIs are compatible.

## Environment Variables

cmux sets these in child shells:

| Variable | Description |
|----------|-------------|
| `CMUX_SOCKET_PATH` | Path to control socket |
| `CMUX_TAB_ID` | UUID of the current tab |
| `CMUX_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
cmux notify --title <text> [--subtitle <text>] [--body <text>] [--tab <id|index>] [--panel <id|index>]
cmux list-notifications
cmux clear-notifications
cmux set-status <key> <value> [--icon <name>] [--color <#hex>] [--workspace <id|ref>]
cmux clear-status <key> [--workspace <id|ref>]
cmux set-agent-pid <key> <pid> [--workspace <id|ref>]
cmux clear-agent-pid <key> [--workspace <id|ref>]
cmux ping
```

## Best Practices

1. **Always check availability first** - Use `command -v cmux` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
