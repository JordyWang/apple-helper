# Apple Helper MCP

本地 macOS MCP 服务，使用 Apple 原生 EventKit 操作提醒事项和日历，支持增删改查。通过标准 stdio 接入 Codex，也可配置到支持本地 MCP 的其他客户端。服务不监听网络端口，不需要 Apple ID 密码或 API Key；日历和提醒事项仍会按系统账户设置同步，工具返回的数据会交给调用它的 AI 客户端。

## 已实现

| 对象 | 查询 | 新建 | 修改 | 删除 |
| --- | --- | --- | --- | --- |
| 提醒事项 | 列表、ID、关键词、完成状态、到期范围、分页 | 标题、备注、日期、优先级、通知 | 内容、日期、完成/未完成、移动列表 | 按 ID 删除 |
| 日程 | 日历、ID、日期范围、关键词、分页、重复事件实例 | 普通和全天日程 | 内容、起止时间、地点、时区、移动日历 | 按 ID 和指定实例删除 |

共 25 个工具：

- `get_status`、`request_access`
- `get_preferences`、`update_preferences`、`get_operation`、`list_operations`
- `reconcile_operation`、`preview_operation_prune`、`prune_operations`
- `get_agenda`、`find_free_slots`、`get_event_series`、`reschedule_event`
- `list_reminder_lists`、`list_reminders`、`get_reminder`、`create_reminder`、`update_reminder`、`delete_reminder`
- `list_calendars`、`list_events`、`get_event`、`create_event`、`update_event`、`delete_event`

列表和日历本身仅提供查询；增删改查针对其中的提醒事项与日程。

## 配套 Skill：apple-planner

MCP 提供工具，配套 Skill 负责把自然语言需求组织成查询、规划、写入和核对流程，包括今日/本周概览、待办整理、寻找空闲时段、改期及完成任务。Skill 源码位于 `skills/apple-planner`，依赖本机 `apple-helper` MCP。

```sh
npm run install:skill
```

该命令将技能安装到用户的 Codex skills 目录，默认允许按上下文自动使用；显式调用示例：

```text
$apple-planner 查看今天的日程和未完成事项，给我一份行动安排。
$apple-planner 把明天下午两点的健身安排推迟一小时，保持原来的时长。
```

技能只在对话任务中运行；每日自动执行需要另行明确设置自动化。默认列表和日历优先使用用户明确保存的偏好，再采用 macOS 系统默认值。

## 1.2 规划、重复事项与恢复

- **统一概览**：`get_agenda` 在一个原生请求中返回指定时间段的日程和未完成提醒，分为 `scheduled`、`due`、`overdue`、`undated`。可指定多个 `calendar_ids` / `reminder_list_ids`；日期型待办按规划时区解释。结果按时间分页，`counts` 和 `total` 覆盖完整查询范围。
- **寻找空闲**：`find_free_slots` 合并所有选定日历的忙碌区间，支持前后缓冲、工作日、工作时间、时长及 IANA 时区。参数优先于已保存偏好，缺少工作时间或时长时明确报错。返回可用窗口和窗口内第一段建议时间，跟随 `next_offset` 获取后续窗口。`availability: free` 和已取消事件不占用；默认全天事件占用，可显式选 `all_day_policy: ignore`。提醒事项本身不占用日历时间。
- **改期并查冲突**：`reschedule_event` 默认在全部日历检查拟议时段，冲突时写入前返回 `SCHEDULE_CONFLICT`。允许重叠时显式传 `conflict_policy: allow`。保留原时长与通知；全天事项按日历天数保持长度，跨夏令时仍为午夜边界。重复系列的冲突检查只覆盖此次移动的实例，响应中的 `conflict_checked_scope` 会说明范围。
- **原生重复规则**：日程、提醒的创建和修改支持 `recurrence`，频率为 daily / weekly / monthly / yearly，支持间隔、星期、月内日期（含负数倒数）、月份、序号筛选、按次数或截止时间结束；省略结束条件为无限重复。`recurrence: null` 清除规则。提醒须有到期日期。完成重复提醒时，返回已完成的历史项及系统生成的 `next_occurrence`。
- **系列范围**：`scope: this` 修改单次并保留其他实例；`future` 修改本次及以后；`all` 从当前系列的首个实例开始。使用 `all` 前调用 `get_event_series`，把其 `version` 传为 `expected_version`，不能拿任意单次版本替代。修改现有重复规则使用 future / all；后续修改可能产生新 ID 或例外，但仍由 EventKit 维护系列关系；操作范围按 `get_event_series` 返回的首项和规则确定，不根据标题推断。
- **异常收尾**：`get_operation` 增加记录 `version`。检查真实事项后，`reconcile_operation` 接收独立 `request_id`、`target_request_id`、`expected_operation_version`、`conclusion` 和说明 `note`。`observed_applied` 需提供刚读取的 `evidence: {kind, id, expected_version, occurrence_start?}`，并核对当前内容；删除则检查原引用不存在。`abandoned` 仅关闭调查，不断言成功或失败。结论明确为当前观察，不是历史执行的原子证明；整个过程不重做原写入。仍存活的原进程不能被提前收尾。
- **日志维护**：先用 `preview_operation_prune({before})` 查看数量，再显式调用 `prune_operations({request_id,before})` 压缩此前已终结记录的参数与结果。未解决的 pending / uncertain 会保留。请求 ID、指纹和状态永久保留，压缩后重放返回 `RESULT_PRUNED`，绝不重新执行。日志不会自行按时间删除。
- **取消与查询效率**：已取消的排队任务不会启动；已经开始的写入继续完成日志，取消不等于撤销。队列有容量和等待期限。提醒完成状态使用原生查询条件，普通列表先分页再序列化，规划工具减少多轮工具调用。

重复规则示例（每周一、三，共 8 次；ISO 星期一为 1）：

```json
{"frequency":"weekly","interval":1,"days_of_week":[{"day":1},{"day":3}],"count":8}
```

每月最后一天：`{"frequency":"monthly","days_of_month":[-1]}`。每月第二个星期二：`{"frequency":"monthly","days_of_week":[{"day":2,"week":2}]}`。`count` 与 `until` 互斥，`until` 为带偏移的时间戳。服务返回完整 `recurrence_rules`；系统可能把单次例外转为无独立规则的事项，拆分后段时自动调整剩余次数。

行为采用 [Apple EventKit 重复规则](https://developer.apple.com/documentation/eventkit/creating-a-recurring-event) 和 [原生实例查询](https://developer.apple.com/documentation/eventkit/retrieving-events-and-reminders)。当前 Mac 实测 2099 年的重复系列只展开首项，因此服务将新重复规则的首项和空闲规划限制在未来 10 年内；超出该范围的日程列表/概览返回 `warnings`，不能推断完整忙闲。普通单次事项仍可查询和创建。该 10 年范围是应用的保守支持范围，不是对 EventKit 极限的断言。

## 1.1 高优先级功能

- **默认目标与偏好**：`get_preferences` 返回系统默认、明确保存的偏好和有效值。`update_preferences` 支持默认列表/日历、时区、常用日程时长、工作日与工作时间；传 `null` 重置。没有明确设置时，不虚构工作时间或常用时长。新建时省略目标 ID 会使用有效默认值；配置的目标失效时会报错，不悄悄换账户。
- **通知**：日程和提醒支持 `alarms` 数组，包含绝对时间或相对提前量。日程的相对通知保持相对形式；提醒的相对通知转换为到期时间的绝对偏移。改期默认同步移动绝对通知，相对日程通知保留提前量；`alarm_policy: "preserve"` 保持绝对通知时间。省略 `alarms` 保留现有通知，`[]` 清空。
- **写入可靠性**：所有数据写入需 `request_id`，修改/删除还需 `expected_version`。同 ID 同参数重放此前结果，同 ID 不同参数拒绝；同标题与时间/到期日的新建默认检测重复。服务保存后重新读取并比较关键字段，删除后检查对象/实例消失，成功返回 `operation.verified: true`。

这是写入接口的版本升级：旧调用须补齐请求 ID 和版本字段，更新后重启 MCP 以刷新工具定义。

### 偏好示例

读取 `get_preferences` 的 `version`，再调用 `update_preferences`：

```json
{
  "request_id": "prefs-unique-request-id",
  "expected_version": "get_preferences 返回的 version",
  "event_duration_minutes": 45,
  "work_hours": { "days": [1, 2, 3, 4, 5], "start": "09:00", "end": "18:00" }
}
```

这些仅为调用示例，不会自动替你设置偏好。日程省略 `end` 时只有已保存常用时长才可创建；更新时只传新 `start` 会保持原持续时长。

### 操作记录与重试

创建/修改/删除/更新偏好时，为每个逻辑动作生成唯一请求 ID。超时后用同一 ID 调用 `get_operation`；`succeeded` 可读取原结果，`pending`/`uncertain` 表示结果不能确定，应查询真实事项后再决定。服务不会自动重做这类写入。`failed` 表示本次在执行副作用前失败。修正参数后用新的 ID。

版本检查基于本机已同步到的数据；发现版本冲突会在写入前拒绝。EventKit 不提供跨设备原子比较并交换，因此这降低并发覆盖风险，但不承诺阻止检查与保存之间所有跨设备竞态。SQLite 记录与 EventKit 也无法共同组成原子事务；保存后若进程中断，记录可能保持 `pending`，重试会停止而不会再创建一份。

偏好与操作记录位于 `~/Library/Application Support/Apple Helper MCP/state.sqlite3`，目录/文件权限分别为 700/600。记录包含操作参数及结果，供排查和结果恢复，不上传到独立服务。可用 `APPLE_HELPER_DATA_DIR` 指定独立数据目录；删除操作记录会失去对应请求的重放保护。没有实现自动撤销或云端备份。

## 安装与启动

要求 macOS 14+、Node.js 20+、Xcode Command Line Tools（`xcrun swiftc`）。原生程序需要在使用它的 Mac 上编译。

```sh
git clone https://github.com/JordyWang/apple-helper.git
cd apple-helper
npm ci --ignore-scripts
npm run build
npm run install:codex
```

安装脚本先备份 Codex 配置，再将服务以 `apple-helper` 注册到用户级配置；其他 MCP 和权限策略保留。启动命令使用 Node 和服务器脚本的绝对路径，不依赖客户端启动时的工作目录。

在 Codex 设置 → MCP 服务器中重启 `apple-helper`，或重启客户端后开启新聊天。在输入框使用 `/mcp` 检查连接。详见 [OpenAI 官方 MCP 配置文档](https://learn.chatgpt.com/docs/extend/mcp?surface=app)。

其他客户端的示例配置（替换为该电脑的实际路径）：

```json
{
  "mcpServers": {
    "apple-helper": {
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/apple-helper/src/server.js"]
    }
  }
}
```

移动项目或更新后删除原来的 Node 安装时，需要重新运行 `npm run install:codex` 更新路径。卸载连接：`codex mcp remove apple-helper`。

## 权限

先调用 `get_status`。若不是 `full_access`，调用 `request_access`，并在系统弹窗中允许访问。系统设置 → 隐私与安全性 → 日历 / 提醒事项中，检查当前宿主（如 ChatGPT、Terminal）或 Apple Helper MCP 的权限。

此服务使用 EventKit 的完整访问权限，与 AppleScript 的“自动化”权限不同。换客户端可能需要重新授权。服务不会修改 TCC 数据库或绕过系统授权。

## 调用示例

先用 `get_preferences` 查看默认目标；需要指定其他目标时，通过列表工具取得真实 ID。请求 ID 必须为每个新动作生成，不能反复沿用下面的示例值：

```json
{
  "name": "create_reminder",
  "arguments": {
    "request_id": "buy-milk-unique-request-id",
    "list_id": "从 list_reminder_lists 返回的 id",
    "title": "买牛奶",
    "due_at": "2026-11-16T18:00:00+08:00",
    "alarm_at": "2026-11-16T18:00:00+08:00",
    "time_zone": "Asia/Shanghai"
  }
}
```

```json
{
  "name": "create_event",
  "arguments": {
    "request_id": "meeting-unique-request-id",
    "calendar_id": "从 list_calendars 返回的 id",
    "title": "项目讨论",
    "start": "2026-11-16T14:00:00+08:00",
    "end": "2026-11-16T15:00:00+08:00",
    "time_zone": "Asia/Shanghai",
    "location": "办公室",
    "alarms": [
      { "type": "relative", "offset_minutes": -10 },
      { "type": "absolute", "at": "2026-11-16T13:00:00+08:00" }
    ]
  }
}
```

完成提醒：读取对象后，向 `update_reminder` 传 `request_id`、`id`、读取的 `version` 作为 `expected_version`，以及 `completed: true`。用 `notes: ""` 清空备注，用 `due_at: null` 或 `due_date: null` 清到期日期，用 `alarms: []` 清通知。旧的 `alarm_at` 单通知字段仍保留，但不能与 `alarms` 同传。

查询工具返回 `items`、`total`、`next_offset`，继续查询时使用 `next_offset`。没有提供 `completed` 时，提醒查询同时包含已完成与未完成项。日程范围上限 366 天，返回与 `[start, end)` 重叠的日程；提醒到期范围为 `[due_after, due_before)`。

## 日期与能力范围

- 时间戳必须带时区偏移或 `Z`；输出时间戳使用 UTC。`time_zone` 使用 IANA 名称，例如 `Asia/Shanghai`。
- 提醒的 `due_date` 为全天日期 `YYYY-MM-DD`，与 `due_at` 互斥。设置到期日不会自动设置通知，需要额外提供 `alarms` 或旧的 `alarm_at`。相对提醒通知要求具体时间的 `due_at`；全天提醒应使用绝对通知。通知数组表示完整替换，不传则保留原有通知。
- 通知数量和类型受具体日历账户限制。若系统保存后截断通知或改写字段，写后核对会返回 `RESULT_UNKNOWN` 并附读回结果，不会把部分写入报告为完整成功。
- 全天日程采用 Mac 当前时区（可用 `get_status` 查询），`start`、`end` 都传当地午夜，`end` 不包含在内。例如 11 月 16 日全天的结束值为 11 月 17 日 00:00。本服务会转换 macOS EventKit 内部的含末秒结束时间。
- 重复日程按实例展开查询。获取、修改、删除时传查询返回的 `occurrence_start`；默认 `scope: "this"` 只操作该次，`scope: "future"` 包含之后各次，`scope: "all"` 使用 `get_event_series` 的版本操作当前系列。修改后应使用最新返回的 ID 与时间。
- 重复提醒事项的修改/删除需要 `allow_recurring: true`；完成后系统可能生成下一次提醒。
- 支持原生重复规则；不操作邀请参会者，不修改或删除带参会者的会议，也不编辑附件、子任务、提醒旗标或定位提醒。
- 写入会作用于真实账户；只读日历会明确报错。写操作超时后应先查询结果，避免重复创建。

## 验证和维护

```sh
npm test             # MCP 协议、参数校验、错误传播；不修改系统数据
npm run test:live    # 使用真实 API 创建临时项目，验证 CRUD，再删除临时项目
npm run test:priority # 独立偏好目录 + 真实 API：默认目标、多通知、版本冲突、并发重放、保存后崩溃
```

实测脚本使用唯一标题和 2099 年的日期，只清理本次创建的 ID。需要已授权的可写列表及日历；当前测试样例以 `Asia/Shanghai` 为时区。若意外退出，`.test-state.json` 会保存已知测试 ID，可据此清理；该文件已被 Git 忽略。

高优先级测试使用唯一标题查询并清理本次测试事项，`.priority-test-state.json` 保存故障时所需的标题与独立状态目录。故障注入只编译到 `bin/eventkit-test-bridge`；生产原生程序不包含故障注入分支。

结构：`src/server.js` 注册 MCP 工具，`src/tools.js` 定义参数，`src/bridge.js` 调用原生程序，`native/EventKitBridge.swift` 执行 EventKit 操作并核对结果，`native/StateStore.swift` 用 SQLite 保存偏好及操作记录并跨进程串行化写入。输入通过 stdin JSON 传递，不拼接 shell 命令。编译产物在 `bin/`，依赖版本由 `package-lock.json` 固定。

参考：[Apple EventKit 文档](https://developer.apple.com/documentation/EventKit/EKEventStore)、[官方 MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/server)。

高级验证：`npm run test:native` 检查夏令时与区间算法，`npm run test:advanced` 用临时事项验证规划、重复范围、冲突改期、崩溃核对及压缩后重放。测试状态与个人偏好隔离，失败时保留 `.advanced-test-state.json` 供精确清理。
