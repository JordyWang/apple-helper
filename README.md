# Apple Helper MCP

通过自然语言操作 Mac 上的 **Apple 日历、提醒事项和备忘录**。当前版本 **v1.4.0，52 个 MCP 工具**。

服务使用标准 **stdio MCP**，不绑定 Codex 账号；Codex、Claude Code、WorkBuddy 等支持本地 stdio 的客户端都可以配置接入。客户端负责理解需求，MCP 负责查询、校验和执行操作。

日历与提醒事项通过 Apple EventKit 访问，备忘录通过 macOS 自动化接口访问。服务不监听网络端口，不要求提供 Apple ID 密码或 API Key；应用数据仍按账户设置同步，工具返回的内容会进入所使用 AI 客户端的上下文。

## 阅读导航

- [功能范围与限制](#功能范围与限制)
- [完整工具目录](#完整工具目录)
- [安装服务](#安装服务)
- [各客户端接入](#各客户端接入)：[Codex](#codex)、[Claude Code](#claude-code)、[WorkBuddy](#workbuddy)
- [首次授权与验证](#首次授权与验证)
- [配套 Skill](#配套-skill)
- [使用示例](#使用示例)
- [写入与恢复约定](#写入与恢复约定)
- [常见问题](#常见问题)
- [更新与卸载](#更新与卸载)
- [开发与测试](#开发与测试)
- [高级操作参考](docs/advanced-usage.md)：重复规则、通知、批量操作、撤销、差异查询等详细语义

## 功能范围与限制

### 能操作什么

| 范围 | 支持的操作 |
| --- | --- |
| 日历事件 | 按日期、日历、关键词查询；新建、修改、删除；普通/全天事件、重复规则、多条时间通知、移动日历、改期并检查冲突 |
| 提醒事项 | 按列表、关键词、完成状态、到期范围查询；新建、修改、完成/恢复未完成、删除；优先级、日期/时间、重复规则、多条时间通知、移动列表 |
| 备忘录 | 列出账户和文件夹；标题/正文搜索与分页；读取纯文本、HTML、附件元数据；新建、改标题、替换正文、追加、移动、删除 |
| 日历与提醒列表 | 查看账户来源；新建、改名、改色、删除整个容器 |
| 备忘录文件夹 | 查看层级、创建顶层或嵌套文件夹、改名、删除 |
| 规划与统计 | 日程/待办概览、空闲时段、冲突检查、将提醒排入日历、批量修改、有限撤销、变更查询、统计 |
| 操作管理 | 查看权限、保存明确设置的偏好、查询操作结果、核对不确定写入、压缩旧日志 |

访问范围是**当前 macOS 用户、已同步到本机且系统接口可访问的账户数据**。例如出现在 Apple 日历中的账户可能被 EventKit 暴露；本项目不直接调用 Google Calendar、Outlook 或其他厂商的云 API。实际读写能力取决于账户、容器权限和系统接口。

### 当前不支持或有边界的能力

| 范围 | 边界 |
| --- | --- |
| 操作系统与连接 | 服务须在 macOS 14+ 本机运行；不支持直接在 Windows/Linux/iOS 上运行；没有 HTTP/SSE 远程端点，不能直接配置为云端网页连接器 |
| 其他 App | 未接入 Mail、Safari、通讯录、信息、Finder 等；不提供任意 AppleScript、Shell 或通用桌面控制工具 |
| 日历 | 不编辑邀请/参会者；带参会者的会议可查询，但拒绝修改和删除；重复系列改期的冲突检查仅覆盖选定实例 |
| 提醒事项 | 不编辑附件、子任务、旗标或定位提醒；设置到期日不会自动添加通知 |
| 备忘录 | 共享笔记只读；加密笔记仅返回元数据，即使已在 Notes 界面临时解锁；不支持锁定/解锁、协作权限管理 |
| 备忘录格式与附件 | 附件仅返回元数据；含附件的正文不能重写/追加。可改标题和同账户移动；含附件的跨账户移动不支持。富格式正文替换需显式允许格式丢失；追加拒绝表格、清单等复杂结构 |
| 批量、撤销与变更 | `batch_update`、`get_changes`、`get_statistics` 只处理日历/提醒；Notes 不支持 `undo_operation`；日历/提醒的撤销也仅覆盖支持的普通单项操作 |
| 删除与定时执行 | 删除日历/列表会删除其中全部内容；Notes 的删除保留期由“最近删除”决定。本服务不提供永久清空 Notes 回收区，也不自带定时任务调度器 |

跨应用操作不构成原子事务。将提醒安排进日历不会自动完成提醒；从笔记提取任务也不会自动改写原笔记。更完整的边界见[高级操作参考](docs/advanced-usage.md)。

## 完整工具目录

以下分组互不重复，合计 **52 个**。客户端可能在工具名前附加服务器前缀；逻辑名称不变。具体参数以客户端取得的工具 schema 为准。

| 分组 | 数量 | 工具 | 用途 |
| --- | ---: | --- | --- |
| 连接与偏好 | 4 | `get_status`、`request_access`、`get_preferences`、`update_preferences` | 查看/请求权限，读取/更新明确选择的默认偏好 |
| 操作记录 | 5 | `get_operation`、`list_operations`、`reconcile_operation`、`preview_operation_prune`、`prune_operations` | 检查写入结果、记录核对结论、压缩日志 |
| 日历事件 | 8 | `list_calendars`、`list_events`、`get_event`、`get_event_series`、`create_event`、`update_event`、`delete_event`、`reschedule_event` | 列表/详情、重复系列、事件增删改查和冲突改期 |
| 提醒事项 | 6 | `list_reminder_lists`、`list_reminders`、`get_reminder`、`create_reminder`、`update_reminder`、`delete_reminder` | 列表/详情、增删改查；完成状态由 update 修改 |
| 概览与排程 | 6 | `get_agenda`、`find_free_slots`、`plan_tasks`、`get_plan`、`apply_plan`、`check_conflicts` | 查忙闲、生成排程草案、执行草案、查冲突 |
| 批量与分析 | 4 | `batch_update`、`undo_operation`、`get_changes`、`get_statistics` | 批量修改、有限撤销、差异和统计 |
| 日历/列表容器 | 7 | `list_sources`、`create_calendar`、`update_calendar`、`delete_calendar`、`create_reminder_list`、`update_reminder_list`、`delete_reminder_list` | 账户来源与容器管理 |
| 备忘录与文件夹 | 12 | `list_note_accounts`、`list_note_folders`、`list_notes`、`get_note`、`create_note`、`update_note`、`append_note`、`move_note`、`delete_note`、`create_note_folder`、`update_note_folder`、`delete_note_folder` | 账户、文件夹、笔记查询及写入 |

工具定义位于 [src/tools.js](src/tools.js)、[src/extensions.js](src/extensions.js) 和 [src/notes-tools.js](src/notes-tools.js)。

## 安装服务

三个客户端共用同一份服务，先完成本节，再选择客户端配置。

### 环境要求

- macOS 14 或更新版本，Apple Silicon 或 Intel Mac。
- Node.js 20 或更新版本，以及 npm。
- Xcode Command Line Tools，能够执行 `xcrun swiftc`。尚未安装时运行 `xcode-select --install`，完成系统安装后继续。
- 在对应 Apple 应用中配置好要访问的账户。

### 下载与编译

```sh
git clone https://github.com/JordyWang/apple-helper.git
cd apple-helper
npm ci --ignore-scripts
npm run build
```

构建产物为 `bin/eventkit-bridge`，需要在使用它的 Mac 上编译。仓库尚未提供 npm 公共安装包，不能用 `npx apple-helper-mcp` 代替上述步骤。

在仓库根目录运行以下命令，取得配置中需要的两个**绝对路径**：

```sh
node -p 'process.execPath'
node -p 'require("node:path").resolve("src/server.js")'
```

后续 JSON/TOML 示例中的 `/absolute/path/to/node` 和 `/absolute/path/to/apple-helper/src/server.js` 都是占位符，须替换成实际输出。路径含空格时，终端命令需加引号；JSON 的 `args` 则使用独立字符串。GUI 客户端未必继承终端的 PATH，因此优先使用 Node 的绝对路径。

## 各客户端接入

文档核对日期：**2026-11-18**。协议兼容不等于完成该客户端的端到端测试。

| 客户端 | 接入方式 | 本项目验证状态 |
| --- | --- | --- |
| Codex | 一键脚本，或 `config.toml` | 已配置并实测 |
| Claude Code，本地运行 | `claude mcp add`，或项目 `.mcp.json` | 官方支持所需协议；尚未完成客户端联调 |
| WorkBuddy，Mac 客户端 | 自定义连接器中的 stdio MCP 配置 | 官方支持所需协议；尚未完成客户端联调 |
| 其他本地 MCP 客户端 | 使用下方相同的 command/args，按客户端格式配置 | 须支持 stdio 与本地进程；未逐一验证 |

### Codex

已安装 Codex CLI 时，在仓库根目录执行：

```sh
npm run install:codex
```

脚本使用 `codex mcp add` 注册服务，写入 Node/服务器脚本的绝对路径，并设置启动超时 15 秒、工具调用超时 150 秒。已有配置会先备份，其他服务和权限策略保留。

没有 CLI，或希望手动配置时，将下面的服务表合并到 `~/.codex/config.toml`；若设置了 `CODEX_HOME`，使用该目录内的 `config.toml`。同名服务表只能保留一份：

```toml
[mcp_servers.apple-helper]
command = "/absolute/path/to/node"
args = ["/absolute/path/to/apple-helper/src/server.js"]
startup_timeout_sec = 15
tool_timeout_sec = 150
enabled = true
```

重新加载客户端的 MCP 连接，必要时重启客户端并开启新聊天。在 CLI 可用 `codex mcp list` 或会话内 `/mcp` 检查配置与连接，再按[首次授权与验证](#首次授权与验证)完成系统授权。配置格式见 [Codex 官方 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp?surface=cli)。

### Claude Code

完成服务构建并安装 Claude Code 后，在本仓库根目录执行：

```sh
claude mcp add --transport stdio --scope user apple-helper -- \
  "$(node -p 'process.execPath')" "$(pwd)/src/server.js"
```

`--scope user` 表示该 Mac 用户的各项目可用。用 `claude mcp get apple-helper` 查看配置，进入 Claude Code 后用 `/mcp` 检查连接。若已有同名配置，先查看并按实际路径更新，不要重复添加。

如果希望配置随某个项目管理，也可以在**要使用工具的项目根目录**创建或合并 `.mcp.json`，作为上述用户级注册的替代方式：

```json
{
  "mcpServers": {
    "apple-helper": {
      "type": "stdio",
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/apple-helper/src/server.js"],
      "timeout": 150000
    }
  }
}
```

JSON 示例中的 `timeout` 是 Claude Code 的单次工具执行超时，单位毫秒。采用 CLI 注册时，也可用 `MCP_TOOL_TIMEOUT=150000 claude` 启动客户端设置全局工具超时；这是 **Claude Code 进程**的环境变量，不是服务端 `env` 参数。项目配置可能需要按客户端提示启用；绝对路径属于具体电脑，分享配置时应让每位使用者替换。

注册、作用域及超时语义见 [Claude Code 官方 MCP 文档](https://code.claude.com/docs/en/mcp)。本项目通过标准 MCP SDK 验证工具协议，尚未在 Claude Code 中逐项联调。

### WorkBuddy

在已完成服务构建的同一台 Mac 上配置：

1. 打开 WorkBuddy 左侧的“专家·技能·连接器”，切换到“连接器”。
2. 点击右上角“自定义连接器”，进入 MCP 配置入口。
3. 添加下面的配置并替换绝对路径。如果编辑的是包含其他服务的文件，只合并 `apple-helper` 条目；保留原有服务。
4. 保存并连接。在新任务中启用该连接器，再执行[首次授权与验证](#首次授权与验证)。

入口及启用方式见 [WorkBuddy 官方连接器说明](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Connector)。

```json
{
  "mcpServers": {
    "apple-helper": {
      "type": "stdio",
      "command": "/absolute/path/to/node",
      "args": ["/absolute/path/to/apple-helper/src/server.js"]
    }
  }
}
```

若界面分字段填写，名称填 `apple-helper`，传输方式选 `stdio`，命令填 Node 绝对路径，参数填 `src/server.js` 的绝对路径。这里不填写 URL、OAuth 或 API Key；系统访问权限在 Mac 本机授予。

[WorkBuddy 官方 MCP 配置说明](https://open.workbuddy.cn/en/docs/connector)支持 `command` / `args` 启动本地进程。其 `timeout` 字段文档定义为**连接超时**，不能直接当作 Claude Code 的单次工具超时使用。较长批次如遇客户端超时，按[写入与恢复约定](#写入与恢复约定)核对结果。

本节针对 WorkBuddy Mac 客户端的自定义连接器；项目尚未上架连接器商店。具体界面可能随版本调整，目前尚未完成 WorkBuddy 客户端联调。

## 首次授权与验证

MCP“已连接”只说明服务器进程能通信，不表示已经获得 Apple 应用权限。

先在客户端中输入：

```text
请调用 apple-helper 的 get_status，检查日历、提醒事项和备忘录权限，先不要新建或修改内容。
```

按需调用 `request_access`，在 macOS 系统弹窗中允许对应访问：

| target | 请求范围 |
| --- | --- |
| `calendar` | 日历完整访问 |
| `reminders` | 提醒事项完整访问 |
| `notes` | 控制 Notes 的自动化权限 |
| `both`，默认值 | 日历 + 提醒事项 |
| `all` | 日历 + 提醒事项 + Notes |

例如，只接入备忘录时可说：“请调用 request_access，target 设为 notes，我会处理系统授权弹窗。”

日历和提醒权限位于“系统设置 → 隐私与安全性 → 日历 / 提醒事项”；Notes 位于“自动化”中宿主对 Notes 的控制权限。换客户端、终端宿主或启动方式后可能需要重新授权。服务不修改 TCC 数据库，也不绕过系统授权。

授权后先进行只读检查：

```text
请列出 apple-helper 可用的日历、提醒列表和备忘录文件夹，并说明哪些可写；不要创建测试事项。
```

日历/提醒预期权限为 `full_access`，Notes 为 `authorized`。Notes 的 `not_running` 只表示应用尚未运行，不等于权限被拒绝。客户端可加载的完整工具集合应为 52 个；若客户端过滤或按需加载工具，界面同时显示的数量可能更少。

## 配套 Skill

**MCP 是执行接口，Skill 是使用这些工具的工作流说明。** 不安装 Skill 也能调用全部工具；安装 Skill 不会代替 MCP 注册、系统授权或扩展底层能力。

| Skill | 用途 |
| --- | --- |
| [apple-planner](skills/apple-planner/SKILL.md) | 今日/本周安排、待办整理、空闲时段、任务排程、改期、完成事项与结果核对 |
| [apple-notes](skills/apple-notes/SKILL.md) | 笔记搜索、编辑/追加、文件夹管理、内容保护及与待办/日程的衔接 |

**Codex**：在仓库根目录运行 `npm run install:skill`。默认安装至 `~/.codex/skills`，支持 `CODEX_HOME`，更新已有文件时保留备份。可显式输入 `$apple-planner` 或 `$apple-notes`。

**Claude Code**：官方支持 `~/.claude/skills/<名称>/SKILL.md`。首次安装可在仓库根目录执行以下命令；`-n` 保留已有文件，因此已有同名技能时应先备份再人工合并更新：

```sh
mkdir -p "$HOME/.claude/skills"
cp -R -n skills/apple-planner skills/apple-notes "$HOME/.claude/skills/"
```

通过 `/apple-planner`、`/apple-notes` 使用，详见 [Claude Code 官方 Skills 文档](https://code.claude.com/docs/en/skills)。仓库中的 `agents/openai.yaml` 是 Codex 元数据，不能代替 Claude Code 的 MCP 配置；保留 `references/` 目录以供技能读取。

**WorkBuddy**：可以先连接 MCP 并直接使用自然语言。官方提供“技能 → 添加技能 → 上传技能”入口导入本地技能包；若自行打包本仓库的技能，应保留各自的 `SKILL.md` 和 `references/`（如有），按界面要求选择包格式，见[官方技能说明](https://www.workbuddy.cn/docs/workbuddy/From-Beginner-to-Expert-Guide/Function-Description/Skills-Market)。当前没有专用安装脚本或已验证的 WorkBuddy 技能包，导入与自动调用仍需验证；`npm run install:skill` 只安装到 Codex。

Skill 在对话任务中工作。每天执行、周期报告等需求，需要另行配置客户端支持的自动化。

## 使用示例

以下自然语言可用于任一已连接并授权的客户端，无需记住工具名：

```text
查看今天的日程和未完成提醒，区分今日截止、逾期和无日期待办。

在工作日历里找明天下午连续 45 分钟的空闲时段，先给出候选时间。

把“整理需求”安排到明天下午的空闲时间，时长 30 分钟，并提前 10 分钟通知。

把周五的“项目评审”推迟一小时，保留时长和通知，检查是否与其他安排冲突。

在备忘录中搜索标题包含“项目讨论”的笔记，先列出匹配项和所在文件夹。

在“项目记录”文件夹新建一篇“本周总结”，正文是：完成原型，下一步整理反馈。

把这段补充内容追加到刚才那篇备忘录末尾，保留已有内容。
```

同名匹配多项时，结合日期、账户和文件夹定位。找不到唯一目标时先澄清；“提取笔记中的待办”与“将待办写入提醒事项”是不同操作。

MCP 调用示例，新建备忘录：

```json
{
  "name": "create_note",
  "arguments": {
    "request_id": "a-new-unique-request-id",
    "title": "项目讨论记录",
    "body_text": "结论：本周完成原型。\n待办：整理需求并安排评审。"
  }
}
```

请求 ID 仅为示例，每个新动作应生成新的 ID。省略目标时，Notes 使用其默认账户/文件夹；日历/提醒优先使用明确保存的偏好，再使用系统默认值。Notes 的 `body_text` 不包含标题行，读取返回的 `text` 通常包含标题行。

更多字段及时间示例见[高级操作参考](docs/advanced-usage.md)。

## 写入与恢复约定

- **请求去重**：新建、修改、删除应用数据等受日志保护的写入需要唯一 `request_id`；同一动作重试使用相同 ID 和完全相同参数，不会重复追加或创建。新动作或修正参数才使用新 ID。排程草案、快照等内部状态工具的参数以各自 schema 为准。
- **版本检查**：修改/删除前读取目标，把当前 `version` 作为 `expected_version`。文件夹和容器的版本来自列表；重复日程还需要实例时间与操作范围。
- **写后核对**：成功写入会读回关键字段并返回 `operation.verified: true`。`replayed: true` 是历史成功结果，需要当前状态时应再次查询。
- **不确定结果**：超时、崩溃或 `RESULT_UNKNOWN` 不代表失败。先用 `get_operation` 和真实对象核对，不能换 ID 盲目再写一遍。取消或关闭客户端也不等于回滚。
- **批量与撤销**：批量可能部分成功，必须查看每项状态；撤销依赖支持的快照，不能恢复所有格式和字段，恢复删除会产生新 ID。删除整个容器及 Notes 操作不支持撤销。
- **删除范围**：删除日历/提醒列表必须传 `delete_contents: true`，包含所有内容；删除非空 Notes 文件夹也需要该字段，覆盖全部后代，默认/共享文件夹受保护。
- **时间与分页**：时间戳携带时区偏移或 Z；全天事件采用 Mac 当地午夜，结束日期不包含在内。普通分页跟随 `next_offset`；变更查询使用专用游标和 `page_token`。

版本检查依据本机已同步状态，不是跨设备原子比较并交换。日志与 Apple 应用无法组成同一事务；服务会保留不确定记录并阻止盲目重放。

偏好、操作日志、撤销快照、排程草案和变更快照默认保存在：

```text
~/Library/Application Support/Apple Helper MCP/state.sqlite3
```

目录/文件权限为 700/600。多个客户端在同一 macOS 用户下默认共享这些偏好和记录；设置 `APPLE_HELPER_DATA_DIR` 可切换为独立状态目录，但不会隔离 Apple 应用数据，跨目录也不共享请求去重记录。删除状态库会失去历史去重和恢复信息，不是卸载连接的必要步骤。

## 常见问题

| 现象 | 检查方式 |
| --- | --- |
| 客户端提示找不到 node | 使用 `node -p 'process.execPath'` 的绝对路径；GUI 的 PATH 可能与终端不同 |
| 原生程序不存在或架构不符 | 在当前 Mac 的仓库根目录重新执行 `npm ci --ignore-scripts` 和 `npm run build` |
| MCP 已连接，但无法访问应用 | 通过该客户端调用 `get_status`，按目标执行 `request_access` 并处理系统弹窗 |
| Notes 返回 `not_running` | 尚未启动 Notes，不是权限拒绝；按 Notes 授权流程继续 |
| 运行 `npm start` 后没有页面 | 正常：它在等待 stdio MCP 消息，不是网页服务器；由客户端启动即可 |
| 只有旧工具，或缺少 Notes 工具 | 确认服务器路径指向更新后的仓库，重新加载 MCP 连接，检查工具过滤设置 |
| `VERSION_CONFLICT` | 目标已改变；重新读取、比较变更和原意，再决定是否写入 |
| `DUPLICATE_FOUND` | 查看已有同名/同时间事项；仅在明确需要额外副本时使用 `allow_duplicate` |
| Notes 报格式或附件限制 | 不用全量重写绕过限制；在 Notes 中编辑复杂内容，或明确授权另建笔记 |
| Notes 搜索 `QUERY_TOO_LARGE` | 一次最多 2,000 个候选项，缩小到账户/文件夹；分页不绕过候选数量限制 |
| 写入超时或 `RESULT_UNKNOWN` | 保留原请求 ID，核对操作日志与当前对象；不要立即换 ID 重试 |
| 无法写入特定账户/容器 | 查看系统返回的可写状态；账户出现在列表中不保证允许所有操作 |

## 更新与卸载

更新前先等待正在执行的写入完成。在仓库中执行：

```sh
git pull --ff-only
npm ci --ignore-scripts
npm run build
```

然后重新加载各客户端的 MCP 连接。若使用 Codex Skill，再执行 `npm run install:skill`；其他客户端按各自方式更新技能。移动仓库或更换 Node 安装位置后，需要同步更新各客户端的绝对路径。

仅移除连接：

- Codex：`codex mcp remove apple-helper`，或删除手动添加的对应服务表。
- Claude Code：用户级安装使用 `claude mcp remove --scope user apple-helper`；项目配置则移除 `.mcp.json` 中的该条目。
- WorkBuddy：在连接器管理页面停用或移除该自定义连接器；只移除 `apple-helper` 的配置。
- Skill 独立安装，如不再使用，另行移除对应客户端内的 `apple-planner` / `apple-notes` 目录。

移除连接不会删除 Apple 应用中的数据；也不会自动删除本机操作记录。

## 开发与测试

### 项目结构

```text
src/server.js                 MCP 服务入口与工具注册
src/tools.js                  基础工具参数
src/extensions.js             排程、批量、撤销、统计等参数
src/notes-tools.js             Notes 工具参数
src/bridge.js                  原生桥接、队列与超时处理
native/EventKitBridge.swift   日历/提醒操作及持久化写入包装
native/Notes.swift            Notes 适配与内容核对
native/NotesScripts.swift     固定 AppleScript，用户输入经类型化参数传递
native/StateStore.swift       SQLite 状态与跨进程写入协调
skills/                       两份配套工作流
scripts/                      构建、安装与真实应用测试
docs/advanced-usage.md        详细操作语义与边界
```

参数通过 stdin JSON 和类型化 Apple-event 参数传递，不拼接成用户可执行脚本。依赖版本由 `package-lock.json` 固定；构建产物和测试状态文件不提交到仓库。

### 验证命令

先执行 `npm run build`。其中 `test:live`、`test:priority`、`test:advanced`、`test:extensions`、`test:notes` 会操作真实 Apple 应用，使用临时事项/容器并进行清理；日历/提醒测试需对应权限，Notes 测试需自动化权限。

| 命令 | 范围 |
| --- | --- |
| `npm test` | MCP 协议、参数校验、错误传播与取消行为；不修改系统应用数据 |
| `npm run test:native` | DST、区间/空闲窗口算法、Notes 转义和内容保护；不修改系统应用数据 |
| `npm run test:live` | 日历与提醒的增删改查 |
| `npm run test:priority` | 默认目标、通知、版本冲突、跨进程去重与保存后崩溃 |
| `npm run test:advanced` | 重复范围、规划、改期冲突、操作核对与压缩 |
| `npm run test:extensions` | 专用容器中的排程、批量、撤销、差异、统计和容器管理 |
| `npm run test:notes` | 专用 Notes 文件夹中的搜索、编辑、追加、移动、附件保护、重放和崩溃保护 |

v1.4.0 已完成本机标准 MCP SDK 与真实应用测试；这不等于已完成所有客户端、macOS 版本和账户类型的验证。

意外退出时，检查对应的 `.test-state.json`、`.priority-test-state.json`、`.advanced-test-state.json`、`.extensions-test-state.json` 或 `.notes-test-state.json`，按记录中的唯一 ID/名称清理。它们已被 Git 忽略。Notes 提供恢复清理命令 `node scripts/live-notes-test.js --cleanup`，应先确认原测试进程已退出并检查记录；正常删除的笔记仍遵循 Notes“最近删除”的保留行为。

故障注入只编译到 `bin/eventkit-test-bridge`，生产原生程序不包含该分支。实现参考 [Apple EventKit 文档](https://developer.apple.com/documentation/EventKit/EKEventStore)和[官方 MCP TypeScript SDK](https://ts.sdk.modelcontextprotocol.io/server)。
