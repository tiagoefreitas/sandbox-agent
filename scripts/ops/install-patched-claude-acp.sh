#!/usr/bin/env bash
# Install a pinned version of the Claude ACP adapter directly from npm and
# reapply the Amplemarket patches in-place, bypassing the ACP registry /
# install-agent CLI path. Needed when the live registry ships a newer
# adapter layout than the one `agents.rs` string-replace anchors target.
#
# Usage:
#   bash /home/agent/repos/sandbox-agent/scripts/ops/install-patched-claude-acp.sh
#
# After this completes, restart sandbox-agent so the in-memory "already
# installed" flag is cleared:
#   sudo systemctl restart sandbox-agent
set -euo pipefail

USER_HOME="${HOME:-/home/agent}"
ADAPTER_VERSION="${ADAPTER_VERSION:-0.23.1}"
ADAPTER_PACKAGE="@zed-industries/claude-agent-acp"
CLAUDE_DIR="${USER_HOME}/.local/share/sandbox-agent/bin/agent_processes/claude"
LAUNCHER="${USER_HOME}/.local/share/sandbox-agent/bin/agent_processes/claude-acp"
ADAPTER_JS="${CLAUDE_DIR}/node_modules/@zed-industries/claude-agent-acp/dist/acp-agent.js"

log()  { printf '[install-patched-claude-acp] %s\n' "$*"; }
die()  { printf '[install-patched-claude-acp] ERROR: %s\n' "$*" >&2; exit 1; }

log "wiping previous install at ${CLAUDE_DIR}"
rm -rf "${CLAUDE_DIR}" "${LAUNCHER}"
mkdir -p "${CLAUDE_DIR}"

log "installing ${ADAPTER_PACKAGE}@${ADAPTER_VERSION} via npm"
npm install --no-audit --no-fund --prefix "${CLAUDE_DIR}" \
  "${ADAPTER_PACKAGE}@${ADAPTER_VERSION}" >/dev/null

[[ -f "${ADAPTER_JS}" ]] || die "adapter JS not found at ${ADAPTER_JS}"

log "writing launcher at ${LAUNCHER}"
cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env sh
set -e
exec '${CLAUDE_DIR}/node_modules/.bin/claude-agent-acp' "\$@"
EOF
chmod +x "${LAUNCHER}"

log "applying Amplemarket patches to ${ADAPTER_JS}"
node - "${ADAPTER_JS}" <<'PATCH_EOF'
const fs = require("node:fs");
const path = process.argv[2];
let src = fs.readFileSync(path, "utf8");

function replaceOnce(before, after, label) {
  if (src.includes(after) && !src.includes(before)) {
    console.log(`[skip] ${label} — already applied`);
    return;
  }
  if (!src.includes(before)) {
    throw new Error(`[patch-missing-anchor] ${label}`);
  }
  src = src.replace(before, after);
  console.log(`[ok]   ${label}`);
}

// 1) Opt into session_state_changed events (used by the idle handler below)
replaceOnce(
  "...createEnvForGateway(this.gatewayAuthMeta),",
  "...createEnvForGateway(this.gatewayAuthMeta),\n                CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS: \"1\",",
  "env: enable CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS",
);

// 2) Handle session_state_changed: idle inside the system/subtype switch
if (!src.includes(`case "session_state_changed":`)) {
  replaceOnce(
    `case "hook_started":`,
    `case "session_state_changed": {\n                                if (message.state === "idle") {\n                                    return { stopReason: "end_turn", usage: {\n                                        inputTokens: session.accumulatedUsage.inputTokens,\n                                        outputTokens: session.accumulatedUsage.outputTokens,\n                                        cachedReadTokens: session.accumulatedUsage.cachedReadTokens,\n                                        cachedWriteTokens: session.accumulatedUsage.cachedWriteTokens,\n                                        totalTokens: session.accumulatedUsage.inputTokens +\n                                            session.accumulatedUsage.outputTokens +\n                                            session.accumulatedUsage.cachedReadTokens +\n                                            session.accumulatedUsage.cachedWriteTokens,\n                                    } };\n                                }\n                                break;\n                            }\n                            case "hook_started":`,
    "switch: session_state_changed idle -> end_turn",
  );
}

// 3) Forward hook/task background events as _adapter/background_event
if (!src.includes(`extNotification("_adapter/background_event"`)) {
  const start = src.indexOf(`case "hook_started":`);
  const todoIdx = src.indexOf(`// Todo: process via status api:`, start);
  const breakIdx = src.indexOf("break;", todoIdx);
  const afterBreak = src.indexOf("\n", breakIdx) + 1;
  const block = `                            case "hook_started":\n                            case "hook_progress":\n                            case "hook_response":\n                            case "files_persisted":\n                            case "task_started":\n                            case "task_notification":\n                            case "task_progress":\n                            case "elicitation_complete":\n                            case "api_retry":\n                                await this.client.extNotification("_adapter/background_event", {\n                                    sessionId: message.session_id ?? params.sessionId,\n                                    eventType: message.subtype,\n                                    data: message,\n                                });\n                                break;\n`;
  src = src.slice(0, start) + block + src.slice(afterBreak);
  console.log("[ok]   switch: forward hook/task cases as _adapter/background_event");
}

// 4) Top-level assistant with stop_reason=end_turn -> return end_turn
if (!src.includes(`message.message.stop_reason === "end_turn"`)) {
  const anchor = `for (const notification of toAcpNotifications(content, message.message.role, params.sessionId, this.toolUseCache, this.client, this.logger, {\n                            clientCapabilities: this.clientCapabilities,\n                            parentToolUseId: message.parent_tool_use_id,\n                            cwd: session.cwd,\n                        })) {\n                            await this.client.sessionUpdate(notification);\n                        }`;
  const inject = `\n                        if (message.type === "assistant" &&\n                            message.parent_tool_use_id === null &&\n                            message.message.stop_reason === "end_turn") {\n                            return { stopReason: "end_turn", usage: sessionUsage(session) };\n                        }`;
  if (!src.includes(anchor)) throw new Error("anchor missing: toAcpNotifications for end_turn insertion");
  src = src.replace(anchor, anchor + inject);
  console.log("[ok]   case assistant: return end_turn on top-level stop_reason");
}

// 5) Return end_turn from the `result` success branch (prevents post-end_turn tool_result re-entry)
if (!src.includes(`// Amplemarket patch: return end_turn from result success`)) {
  const anchor = `                                if (isLocalOnlyCommand) {\n                                    for (const notification of toAcpNotifications(message.result, "assistant", params.sessionId, this.toolUseCache, this.client, this.logger)) {\n                                        await this.client.sessionUpdate(notification);\n                                    }\n                                }\n                                break;\n                            }\n`;
  const replacement = `                                if (isLocalOnlyCommand) {\n                                    for (const notification of toAcpNotifications(message.result, "assistant", params.sessionId, this.toolUseCache, this.client, this.logger)) {\n                                        await this.client.sessionUpdate(notification);\n                                    }\n                                }\n                                // Amplemarket patch: return end_turn from result success\n                                if (message.stop_reason === "end_turn" && !isLocalOnlyCommand) {\n                                    return { stopReason: "end_turn", usage };\n                                }\n                                break;\n                            }\n`;
  if (!src.includes(anchor)) throw new Error("anchor missing: result success break for end_turn-from-result patch");
  src = src.replace(anchor, replacement);
  console.log("[ok]   case result success: return end_turn on stop_reason=end_turn");
}

// 6) emitResumedEndTurnIfComplete + unstable_resumeSession hook (+ extractTextContent helper)
if (!src.includes(`extNotification("_adapter/resumed_end_turn"`)) {
  replaceOnce(
    `    async unstable_resumeSession(params) {\n        const result = await this.getOrCreateSession(params);\n`,
    `    async unstable_resumeSession(params) {\n        const result = await this.getOrCreateSession(params);\n        await this.emitResumedEndTurnIfComplete(params.sessionId);\n`,
    "unstable_resumeSession: call emitResumedEndTurnIfComplete",
  );
  replaceOnce(
    `    async replaySessionHistory(sessionId) {\n        const toolUseCache = {};\n`,
    `    async emitResumedEndTurnIfComplete(sessionId) {\n        const messages = await getSessionMessages(sessionId);\n        for (let i = messages.length - 1; i >= 0; i--) {\n            const message = messages[i];\n            if (message.type !== "assistant" || message.parent_tool_use_id !== null) {\n                continue;\n            }\n            const isTextOnlyNullStop = message.message.stop_reason === null &&\n                Array.isArray(message.message.content) &&\n                message.message.content.length > 0 &&\n                message.message.content.every((item) => item && (item.type === "text" || item.type === "thinking")) &&\n                message.message.content.some((item) => item && item.type === "text" && typeof item.text === "string" && item.text.trim().length > 0);\n            if (message.message.stop_reason !== "end_turn" && !isTextOnlyNullStop) {\n                return;\n            }\n            await this.client.extNotification("_adapter/resumed_end_turn", {\n                sessionId,\n                stopReason: "end_turn",\n                text: extractTextContent(message.message.content),\n            });\n            return;\n        }\n    }\n    async replaySessionHistory(sessionId) {\n        const toolUseCache = {};\n`,
    "define emitResumedEndTurnIfComplete",
  );
  replaceOnce(
    `function sessionUsage(session) {\n    return {\n`,
    `function extractTextContent(content) {\n    if (typeof content === "string") return content;\n    if (!Array.isArray(content)) return "";\n    return content.filter((item) => item?.type === "text" && typeof item.text === "string").map((item) => item.text).join("\\n").trim();\n}\nfunction sessionUsage(session) {\n    return {\n`,
    "define extractTextContent helper",
  );
}

// 7) In-loop idle-timeout escape hatch (Promise.race + JSONL-mtime gate)
if (!src.includes("AMPLEMARKET_IDLE_SENTINEL")) {
  const anchor = `session.promptRunning = true;\n        let handedOff = false;\n        try {\n            while (true) {\n                const { value: message, done } = await session.query.next();\n`;
  const replacement = `session.promptRunning = true;\n        let handedOff = false;\n        const AMPLEMARKET_IDLE_CHECK_MS = 300000;\n        const AMPLEMARKET_JSONL_IDLE_MS = 240000;\n        const AMPLEMARKET_IDLE_SENTINEL = Symbol.for("amplemarket-acp-idle");\n        let pendingNextPromise = null;\n        const resolveJsonlPath = () => {\n            try {\n                const p = require("node:path");\n                const o = require("node:os");\n                const cwd = session && session.cwd ? session.cwd : process.cwd();\n                const slug = cwd.replace(/[\\\\/]/g, "-");\n                return p.join(o.homedir(), ".claude", "projects", slug, \`\${params.sessionId}.jsonl\`);\n            } catch { return null; }\n        };\n        const amplemarketCheckJsonlForAbandonedEndTurn = async () => {\n            try {\n                const fsMod = require("node:fs");\n                const jsonlPath = resolveJsonlPath();\n                if (jsonlPath) {\n                    try {\n                        const st = fsMod.statSync(jsonlPath);\n                        if (Date.now() - st.mtimeMs < AMPLEMARKET_JSONL_IDLE_MS) return null;\n                    } catch { return null; }\n                }\n                const msgs = await getSessionMessages(params.sessionId);\n                for (let i = msgs.length - 1; i >= 0; i--) {\n                    const m = msgs[i];\n                    if (!m || m.type !== "assistant" || m.parent_tool_use_id !== null) continue;\n                    const c = m.message && m.message.content;\n                    const hasText = Array.isArray(c) && c.some((it) => it && it.type === "text" && typeof it.text === "string" && it.text.trim().length > 0);\n                    if (!hasText) return null;\n                    const s = m.message.stop_reason;\n                    if (s === "end_turn" || s === null) return m;\n                    return null;\n                }\n                return null;\n            } catch { return null; }\n        };\n        try {\n            while (true) {\n                if (!pendingNextPromise) { pendingNextPromise = session.query.next(); }\n                const timerPromise = new Promise((resolve) => { setTimeout(() => resolve(AMPLEMARKET_IDLE_SENTINEL), AMPLEMARKET_IDLE_CHECK_MS); });\n                const race = await Promise.race([pendingNextPromise, timerPromise]);\n                if (race === AMPLEMARKET_IDLE_SENTINEL) {\n                    const finalA = await amplemarketCheckJsonlForAbandonedEndTurn();\n                    if (finalA) { return { stopReason: "end_turn", usage: sessionUsage(session) }; }\n                    continue;\n                }\n                const { value: message, done } = race;\n                pendingNextPromise = null;\n`;
  if (!src.includes(anchor)) throw new Error("anchor missing: prompt while-loop for idle-timeout patch");
  src = src.replace(anchor, replacement);
  console.log("[ok]   prompt while-loop: idle-timeout + JSONL fallback");
}

fs.writeFileSync(path, src);
console.log(`[done] wrote ${path}`);
PATCH_EOF

log "patched ${ADAPTER_JS}"
log "syntax check"
node -e "require('${ADAPTER_JS}'); console.log('adapter loads OK');"

log "done — now: sudo systemctl restart sandbox-agent"
