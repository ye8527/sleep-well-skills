# sleep-well skills

Two companion skills for unattended, queue-driven coding work on macOS:

- `sleep-well/`: Claude-driven orchestration with Codex review.
- `sleep-well-codex/`: shell-driven orchestration with Codex implementation and Claude review.

Both variants keep resumable state on disk, checkpoint work locally, and apply guardrails around destructive or external actions. Read each `SKILL.md` and review its configuration and limitations before enabling unattended runs.

## Install

Clone this repository, then copy the variant you want:

```bash
cp -R sleep-well ~/.claude/skills/sleep-well
cp -R sleep-well-codex ~/.codex/skills/sleep-well-codex
```

The two variants can share `~/sleep-well/queue.md`. They require Node.js, Git, and the corresponding Claude/Codex command-line tools. Optional integrations described in the skill files must be installed separately.

## Test

```bash
(cd sleep-well && npm test)
(cd sleep-well-codex && npm test)
```

The Codex native-web probe is intentionally excluded from the normal suite because it performs a real model/tool call.

## Safety

These skills can modify files and create local Git commits while unattended. They are designed not to push, deploy, merge, migrate databases, or perform other external/destructive actions automatically. The documented sandbox and guardrail limitations still apply; use a dedicated low-privilege account or isolated environment when stronger read isolation is required.

The launchd files are templates for macOS. Inspect them before copying to `~/Library/LaunchAgents/`; the Claude watchdog is disabled by default.

