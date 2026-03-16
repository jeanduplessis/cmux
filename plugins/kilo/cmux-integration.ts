/**
 * cmux Rich Integration Plugin for Kilo Code
 *
 * Provides Claude Code-level integration with cmux:
 * - Sidebar status updates (Running / Idle / Needs input / Error)
 * - Targeted notifications (completion, permission prompts, errors)
 * - OSC notification suppression via agent PID registration
 * - Automatic cleanup on process exit with stale PID sweep as safety net
 *
 * Install:
 *   cp plugins/kilo/cmux-integration.ts ~/.config/kilo/plugins/cmux-integration.ts
 *
 * Or symlink:
 *   ln -s "$(pwd)/plugins/kilo/cmux-integration.ts" ~/.config/kilo/plugins/cmux-integration.ts
 */

import { execSync, spawnSync } from "node:child_process";

// ── Status constants ────────────────────────────────────────────────
const AGENT_KEY = "kilo_code";

const STATUS = {
  running: {
    value: "Running",
    icon: "bolt.fill",
    color: "#4C8DFF",
  },
  idle: {
    value: "Idle",
    icon: "pause.circle.fill",
    color: "#8E8E93",
  },
  needsInput: {
    value: "Needs input",
    icon: "bell.fill",
    color: "#4C8DFF",
  },
  error: {
    value: "Error",
    icon: "exclamationmark.triangle.fill",
    color: "#FF3B30",
  },
} as const;

// ── Helpers ─────────────────────────────────────────────────────────

// (Individual helper functions below handle cmux CLI calls directly)

/**
 * Set sidebar status for this agent.
 */
async function setStatus(
  $: any,
  status: (typeof STATUS)[keyof typeof STATUS],
  workspace: string | undefined,
  customValue?: string,
) {
  const value = customValue ?? status.value;
  try {
    const args: string[] = [
      "set-status",
      AGENT_KEY,
      value,
      "--icon",
      status.icon,
      "--color",
      status.color,
    ];
    if (workspace) {
      args.push("--workspace", workspace);
    }
    await $`cmux ${args}`.nothrow();
  } catch {
    // ignore
  }
}

/**
 * Send a notification via cmux CLI.
 */
async function notify(
  $: any,
  {
    title,
    subtitle,
    body,
    workspace,
    surface,
  }: {
    title: string;
    subtitle?: string;
    body?: string;
    workspace?: string;
    surface?: string;
  },
) {
  try {
    const args: string[] = ["notify", "--title", title];
    if (subtitle) {
      args.push("--subtitle", subtitle);
    }
    if (body) {
      args.push("--body", body);
    }
    if (workspace) {
      args.push("--workspace", workspace);
    }
    if (surface) {
      args.push("--surface", surface);
    }
    await $`cmux ${args}`.nothrow();
  } catch {
    // ignore
  }
}

/**
 * Clear notifications via cmux CLI.
 */
async function clearNotifications(
  $: any,
  workspace: string | undefined,
) {
  try {
    const args: string[] = ["clear-notifications"];
    if (workspace) {
      args.push("--workspace", workspace);
    }
    await $`cmux ${args}`.nothrow();
  } catch {
    // ignore
  }
}

/**
 * Synchronous cleanup using execSync — suitable for process "exit" handlers
 * where async operations won't complete.
 */
function cleanupSync(workspace: string | undefined) {
  const wsArgs = workspace ? ["--workspace", workspace] : [];
  try {
    spawnSync("cmux", ["clear-status", AGENT_KEY, ...wsArgs], {
      timeout: 2000,
      stdio: "ignore",
    });
  } catch {
    // ignore
  }
  try {
    spawnSync("cmux", ["clear-agent-pid", AGENT_KEY, ...wsArgs], {
      timeout: 2000,
      stdio: "ignore",
    });
  } catch {
    // ignore
  }
  try {
    spawnSync("cmux", ["clear-notifications", ...wsArgs], {
      timeout: 2000,
      stdio: "ignore",
    });
  } catch {
    // ignore
  }
}

// ── Verbose tool status description ─────────────────────────────────

function describeToolUse(tool: string, args: Record<string, any>): string {
  switch (tool) {
    case "bash":
    case "execute_command": {
      const cmd = args.command || args.cmd || "";
      const firstWord = String(cmd).split(/\s+/)[0] || "command";
      return `Running ${firstWord}`;
    }
    case "read":
    case "read_file": {
      const filePath = args.filePath || args.path || args.file || "";
      const name = String(filePath).split("/").pop() || "file";
      return `Reading ${name}`;
    }
    case "edit":
    case "apply_diff": {
      const filePath = args.filePath || args.path || args.file || "";
      const name = String(filePath).split("/").pop() || "file";
      return `Editing ${name}`;
    }
    case "write":
    case "write_to_file": {
      const filePath = args.filePath || args.path || args.file || "";
      const name = String(filePath).split("/").pop() || "file";
      return `Writing ${name}`;
    }
    case "glob":
    case "list_files": {
      const pattern = args.pattern || args.glob || "";
      return `Searching ${pattern || "files"}`;
    }
    case "grep":
    case "search_files": {
      const pattern = args.pattern || args.regex || args.query || "";
      return `Grep ${pattern || "pattern"}`;
    }
    case "task":
      return "Running task";
    case "webfetch":
    case "url_screenshot":
      return "Fetching URL";
    case "websearch":
      return "Searching web";
    case "codesearch":
      return "Searching code";
    default:
      return tool;
  }
}

// ── Plugin entry point ──────────────────────────────────────────────

export const CmuxIntegration = async ({
  $,
  directory,
}: {
  $: any;
  directory: string;
  [key: string]: any;
}) => {
  // ── Guard: skip if not running inside cmux ──
  const socketPath =
    process.env.CMUX_SOCKET_PATH || process.env.CMUX_SOCKET;
  const workspace =
    process.env.CMUX_WORKSPACE_ID || process.env.CMUX_TAB_ID;
  const surface =
    process.env.CMUX_SURFACE_ID || process.env.CMUX_PANEL_ID;
  const verbose = !!process.env.CMUX_KILO_VERBOSE;

  if (!socketPath) {
    // Not running inside cmux — return empty hooks (no-op)
    return {};
  }

  // ── Verify cmux is reachable ──
  try {
    execSync("cmux ping", { timeout: 2000, stdio: "ignore" });
  } catch {
    // cmux not responding — return empty hooks
    return {};
  }

  // ── State ──
  let isRunning = false;
  let lastAssistantMessage = "";
  let cleanedUp = false;

  const projectName = directory
    ? String(directory).split("/").pop() || "project"
    : "project";

  // ── Register agent PID ──
  try {
    const pidArgs: string[] = [
      "set-agent-pid",
      AGENT_KEY,
      String(process.pid),
    ];
    if (workspace) pidArgs.push("--workspace", workspace);
    await $`cmux ${pidArgs}`.nothrow();
  } catch {
    // ignore
  }

  // ── Set initial Idle status ──
  await setStatus($, STATUS.idle, workspace);

  // ── Register cleanup handlers ──
  function cleanup() {
    if (cleanedUp) return;
    cleanedUp = true;
    cleanupSync(workspace);
  }

  process.on("exit", cleanup);
  process.on("SIGINT", () => {
    cleanup();
    process.exit(128 + 2);
  });
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(128 + 15);
  });

  // ── Return hooks ──
  return {
    event: async ({ event }: { event: { type: string; properties?: any; [key: string]: any } }) => {
      try {
        switch (event.type) {
          case "session.idle": {
            // Build completion notification
            const subtitle = `Completed in ${projectName}`;
            const body =
              lastAssistantMessage ||
              "Turn complete";
            await notify($, {
              title: "Kilo Code",
              subtitle,
              body: body.slice(0, 200),
              workspace,
              surface,
            });
            await setStatus($, STATUS.idle, workspace);
            isRunning = false;
            break;
          }

          case "session.error": {
            await notify($, {
              title: "Kilo Code",
              subtitle: "Error",
              body: "Session encountered an error",
              workspace,
              surface,
            });
            await setStatus($, STATUS.error, workspace);
            isRunning = false;
            break;
          }

          case "permission.asked": {
            // Extract details from event data if available
            const props = event.properties || event;
            const tool = props.tool || props.toolName || "";
            const body = tool
              ? `Approval needed for ${tool}`
              : "Approval needed";
            await notify($, {
              title: "Kilo Code",
              subtitle: "Permission",
              body,
              workspace,
              surface,
            });
            await setStatus($, STATUS.needsInput, workspace);
            break;
          }

          case "permission.replied": {
            await clearNotifications($, workspace);
            if (!isRunning) {
              await setStatus($, STATUS.running, workspace);
              isRunning = true;
            }
            break;
          }

          case "message.updated": {
            // Track the last assistant message for completion notifications.
            // The event data structure varies — try common shapes defensively.
            try {
              const props = event.properties || event;
              const content =
                props.content ||
                props.text ||
                props.message?.content ||
                props.message?.text ||
                "";
              const role =
                props.role ||
                props.message?.role ||
                "";
              if (
                role === "assistant" &&
                typeof content === "string" &&
                content.length > 0
              ) {
                lastAssistantMessage = content.slice(0, 200);
              }
            } catch {
              // ignore — defensive handling
            }
            break;
          }

          case "message.part.updated": {
            // Agent started responding — set Running status
            if (!isRunning) {
              await setStatus($, STATUS.running, workspace);
              isRunning = true;
            }
            break;
          }

          default:
            break;
        }
      } catch {
        // Individual event handlers must never crash the plugin
      }
    },

    "tool.execute.before": async (
      input: { tool: string; sessionID?: string; callID?: string },
      output: { args: Record<string, any> },
    ) => {
      try {
        // Clear any pending notifications (permission was granted, agent resumed)
        await clearNotifications($, workspace);

        // Determine status value
        let statusValue = "Running";
        if (verbose) {
          statusValue = describeToolUse(input.tool, output.args);
        }

        await setStatus($, STATUS.running, workspace, statusValue);
        isRunning = true;
      } catch {
        // ignore
      }
    },
  };
};
