# sleep-well 韧性看门狗 (Resilience Watchdog)

## 默认状态：OFF（未安装）

看门狗 plist 文件已预置在技能仓库内：

```
~/.claude/skills/sleep-well/bin/com.user.sleepwell-watchdog.plist
```

它**尚未**复制到 `~/Library/LaunchAgents/`，也**未**被 `launchctl` 加载。
除非你主动"武装"它（见下文），它对你的系统完全无影响。

---

## 它每 5 分钟做什么

1. **无论如何，先从磁盘刷新晨报**（不需要任何 Claude 会话）：
   ```sh
   node ~/.claude/skills/sleep-well/bin/report.mjs
   ```
   这会更新 `~/sleep-well/morning-report.md`。即使 Claude 完全宕机，这一步也能正常工作。

2. 如果 `~/sleep-well/STOP` 存在，或 `state/current-run.json` 不存在 → 退出（无动作）。

3. 如果心跳文件（`state/heartbeat`）的修改时间超过 20 分钟 → 尝试无头恢复：
   ```sh
   claude -p "Resume the sleep-well night shift: run the sleep-well skill, ..."
   ```

---

## 武装（仅在最坏情况下使用）

```bash
cp ~/.claude/skills/sleep-well/bin/com.user.sleepwell-watchdog.plist \
   ~/Library/LaunchAgents/
launchctl load -w ~/Library/LaunchAgents/com.user.sleepwell-watchdog.plist
```

验证已加载：
```bash
launchctl list | grep sleepwell-watchdog
```

## 解除武装

```bash
launchctl unload ~/Library/LaunchAgents/com.user.sleepwell-watchdog.plist
rm ~/Library/LaunchAgents/com.user.sleepwell-watchdog.plist
```

---

## 重要注意事项（Honest Caveats）

### 无头会话 vs. 桌面客户端

看门狗只能调用 `claude -p "…"`，这会产生一个**独立的无头会话**——不是你的桌面 Claude Code 客户端窗口。

- 无头会话**没有可见 UI**，无法从手机 app 实时操控。
- 如果桌面客户端已在运行 `/loop sleep-well`，看门狗会产生**第二个竞争会话**；脚本本身不会检测这种情况（你需要在武装前确认桌面会话已死亡）。
- 如果 `claude` CLI 未安装或未为无头使用授权，**只有第 1 步（报告刷新）会工作**——但那本身就已经很有价值。

### 每 5 分钟一次，不是真正的 ScheduleWakeup 循环

无头 `claude -p` 每次 tick 运行一次单步恢复，不是连续的 `/loop` 循环。如果 Anthropic 服务正常，每个 tick 可能推进一个任务；如果服务完全中断，tick 会失败但下次 tick 会再试。

### 报告刷新：完全无需 Claude

```bash
node ~/.claude/skills/sleep-well/bin/report.mjs
```

这个命令**完全不依赖 Claude**——它只读磁盘上的 JSON/JSONL 文件并生成 Markdown。即使 Anthropic 全面宕机，晨报也会被持续更新。

---

## 为何磁盘状态保证工作不丢失

`saveState` 在每次状态转换后都会写入 `current-run.json`，未提交的代码变更保留在工作树上。任何级别的中断只会丢失**时间**，不会丢失**工作**。重开 `/loop sleep-well` 即可从磁盘精确恢复。

---

## 快速参考

| 操作 | 命令 |
|---|---|
| 仅刷新报告（无 Claude） | `node ~/.claude/skills/sleep-well/bin/report.mjs` |
| 武装看门狗 | `cp …plist ~/Library/LaunchAgents/ && launchctl load -w …plist` |
| 解除武装 | `launchctl unload …plist && rm …plist` |
| 手动停止，不卸载 | `touch ~/sleep-well/STOP` |
| 恢复 | `rm ~/sleep-well/STOP` 然后重开 `/loop sleep-well` |
