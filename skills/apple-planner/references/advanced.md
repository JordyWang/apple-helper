# 重复事项、恢复与维护

## 重复规则

`create_event` / `create_reminder` 和对应更新接口支持 `recurrence`，省略保留，`null` 清除。提醒必须有到期日。使用原生规则表达无限重复。

- 每日：`{"frequency":"daily","interval":1}`。
- 每周一、三，共八次：`{"frequency":"weekly","days_of_week":[{"day":1},{"day":3}],"count":8}`；星期为 ISO 周一 1 至周日 7。
- 每月最后一天：`{"frequency":"monthly","days_of_month":[-1]}`。
- 每月第二个周二：`{"frequency":"monthly","days_of_week":[{"day":2,"week":2}]}`。
- 每年七月：`{"frequency":"yearly","months_of_year":[7]}`，具体日期来自首项。
- `count` 与带时区的 `until` 只能选一项；均省略则不设结束条件。

编辑重复规则使用 `future` 或 `all`，不能将系列规则改动伪装成单次编辑。`all` 必须先读取 `get_event_series`，将返回的 `version` 用作 `expected_version`。`future` 的修改可能产生新 ID 或例外，但 EventKit 仍可能将它们关联到母系列。`all` 的范围以系统返回的首项和规则为准；不要按标题猜测，也不要承诺改过 ID 的后续事项一定不受影响。

单次修改会生成例外，可能不再携带独立重复规则。修改后使用返回的最新 ID、实例时间和版本。若从例外无法唯一找到母系列，查询一个未修改实例定位，不能猜测父系列。

创建或完成重复提醒后查询实际状态。完成响应若含 `next_occurrence`，顶层对象表示已完成的历史项，嵌套对象表示下一次。它们可能使用不同 ID。

新重复规则的首项与空闲规划支持未来 10 年内；极远年份的 EventKit 查询不能可靠展开重复实例。列表/概览返回 `warnings` 时说明范围，不据此保证空闲或报告完整系列。

## 异常操作核对

超时或 `RESULT_UNKNOWN` 后，先以原 `request_id` 调用 `get_operation`，再读取真实事项。使用相同 ID 的重试不会重复写入；不要用新 ID 盲目重做。

确定当前观察后可用 `reconcile_operation` 收尾，提供新 `request_id`、原 `target_request_id`、记录的 `expected_operation_version`、`conclusion` 和 `note`：

- `observed_applied`：提供刚读取的 `evidence: {kind:"event"|"reminder",id,expected_version,occurrence_start?}`；服务器核对当前内容。删除操作检查原引用不存在。
- `abandoned`：关闭调查并说明原因，不表示操作失败或成功。

结论仅证明当前观察，不证明历史上由哪个调用造成；不要把它描述成原子事务恢复。原进程仍活跃时等待完成；版本变化后重新读取。核对工具不执行原写入。

## 日志压缩

只有用户要求维护日志时，先 `preview_operation_prune({before})` 查看范围，再 `prune_operations({request_id,before})`。它清除旧终结记录的正文及撤销快照，保留请求 ID、指纹与状态；未解决记录保留。压缩后的记录不能撤销，重放返回 `RESULT_PRUNED`，不能换 ID 重做原操作。需要当前结果时查询真实事项。
