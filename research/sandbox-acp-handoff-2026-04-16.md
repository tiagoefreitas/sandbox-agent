# Sandbox ACP Handoff

## Scope

This repo carries the `sandbox-agent` side of the Sherlock + Claude ACP debugging work:

- ACP request timeout
- same-session resume correctness
- persisted server affinity for sessions
- Claude ACP adapter patch durability
- resumed completion signaling

## Repos And Branches

Work on these repos / branches:

- primary repo: `amplemarket/sandbox-agent`
- primary branch: `ample/upstream-claude-acp-fixes`
- local path: [sandbox-agent](/home/agent/repos/sandbox-agent)

Personal mirror:

- personal repo: `tiagoefreitas/sandbox-agent`
- personal branch: `ample/upstream-claude-acp-fixes`

Companion Sherlock repo:

- repo: `amplemarket/sherlock`
- branch: `sandbox`
- local path: [sherlock](/home/agent/repos/sherlock)

Do not continue from these old mistaken branches:

- `ample/private-release-systemd-plan`
- `ample/upstream-claude-acp-fixes-main`

## Findings

1. The 2-hour ACP timeout is necessary but not sufficient.
   - It fixes the old HTTP transport timeout class.
   - It does not fix dropped completion semantics or stale client/server session mapping.

2. The most important resume bug was in the TypeScript SDK.
   - During `resumeSession()`, local session binding happened after `unstable_resumeSession()`.
   - Notifications emitted during the resume RPC had no local session mapping and were dropped.
   - This broke resumed completion delivery.

3. Claude adapter behavior needed patching in the installed ACP adapter.
   - background events needed a stable ACP extension notification shape
   - top-level assistant `end_turn` needed to become a terminal ACP result
   - resumed already-completed sessions needed a resume-specific completion notification

## Changes

### SDK

Files:

- [sdks/typescript/src/client.ts](/home/agent/repos/sandbox-agent/sdks/typescript/src/client.ts)
- [sdks/typescript/src/types.ts](/home/agent/repos/sandbox-agent/sdks/typescript/src/types.ts)

What changed:

- persisted sessions now store `serverId`
- `getLiveConnection()` can prefer the original ACP server id
- `resumeSession()` reattaches to the original server instead of inventing a fresh one first
- local binding now happens before `unstable_resumeSession()`
- missing/unsupported remote resumes fall back cleanly to recreate-and-replay
- send-path recovery also recreates if the remote session is gone

### Claude adapter patching

File:

- [server/packages/agent-management/src/agents.rs](/home/agent/repos/sandbox-agent/server/packages/agent-management/src/agents.rs)

What changed:

- durable source patching for installed Claude ACP adapter now injects:
  - `CLAUDE_CODE_EMIT_SESSION_STATE_EVENTS=1`
  - idle/session-state completion handling
  - `_adapter/background_event`
  - terminal completion from assistant `stop_reason === "end_turn"`
  - `_adapter/resumed_end_turn` during resume if the resumed session had already completed

### ACP proxy timeout

Files:

- [server/packages/sandbox-agent/src/acp_proxy_runtime.rs](/home/agent/repos/sandbox-agent/server/packages/sandbox-agent/src/acp_proxy_runtime.rs)
- [scripts/ops/prepare-systemd-private-release.sh](/home/agent/repos/sandbox-agent/scripts/ops/prepare-systemd-private-release.sh)

What changed:

- default ACP request timeout increased to 2 hours
- private systemd release script injects `SANDBOX_AGENT_ACP_REQUEST_TIMEOUT_MS=7200000`

### Persist examples

Files:

- [examples/persist-sqlite/src/persist.ts](/home/agent/repos/sandbox-agent/examples/persist-sqlite/src/persist.ts)
- [examples/persist-postgres/src/persist.ts](/home/agent/repos/sandbox-agent/examples/persist-postgres/src/persist.ts)

What changed:

- persistence examples were updated to store and read `serverId`

## Validation

### Rust test

```bash
cd /home/agent/repos/sandbox-agent
source ~/.cargo/env
cargo test -p sandbox-agent-agent-management agents::tests::install_claude_patches_adapter_for_idle_and_background_events -- --exact
```

### Runtime resume proof

Using the compiled `sandbox-agent` runtime that Sherlock loads:

1. create a Claude session
2. prompt `Reply with exactly OK`
3. dispose the first client
4. resume the same session with a fresh client
5. confirm persisted `_adapter/resumed_end_turn`

Observed:

```json
{
  "stopReason": "end_turn",
  "text": "OK"
}
```

## Remaining Issue

The remaining problem is mostly in Sherlock, not here:

- a long-running/report-finished session can still finalize late
- the same session is preserved
- the final Slack reply eventually lands
- but Sherlock can still need a late reconnect / synthetic continue before it posts that final reply

That means the `sandbox-agent` resume/completion transport path is materially improved, but Sherlock still needs better late-finalization logic.
