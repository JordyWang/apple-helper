# 任务排程、批量与观察

## 待办排程

用查询结果中的真实提醒 ID 选择任务，不按标题猜 ID。调用 `plan_tasks`，提供范围和 `tasks`，逐项可给 `duration_minutes`、`earliest_start`、`deadline`，也可用总的默认时长及已保存工作时间。明确估算时长只用于本次规划，不写成长期偏好。

默认按截止日期再优先级安排，可用 `priority_then_deadline`。日期型到期日在规划时区当天结束；显式 deadline 优先。工具不拆分任务，未排入项有原因，不能把未排入说成已安排。选择需要查冲突的日历；目标日历始终参与检查，默认覆盖全部日历。缓冲和全天占用按用户需求处理。

草案有效期 7 天，`get_plan` 读取原草案及当前关联日程。用户仅要建议时止于草案；已授权执行时直接 `apply_plan`，提供新 request_id、plan_id 和草案 version 作为 expected_plan_version。执行前重新检查提醒版本和冲突；不自动完成提醒。返回关联日程可能已被用户移动或删除，以 current_event / state 为准，草案时间不是永久当前状态。

## 批量更新与部分结果

最多 50 项，每项有唯一 key、kind、id、expected_version 和 changes。重复事件的 scope / occurrence_start、重复提醒 allow_recurring 与单项工具相同。批量修改本身不自动查改期冲突；需要避让时先查窗口或逐项使用 reschedule_event。不要在一个批次中多次修改同一对象。

默认明确失败后停止，用户任务适合独立执行时可选择 on_error=continue。不确定写入始终停止。检查 succeeded_count / failed_count / uncertain_count / not_started_count 和每项结果；父响应不是原子事务。

同父 request_id、同参数重试会跳过成功项，仅重试确认未写入的失败项。修正参数后用新批次并重新读取仍待处理项，不再次带入已完成项。pending / uncertain 子请求先 get_operation 并读取真实数据，不用新 ID 绕过保护。取消让当前步骤完成后停止后续项，不表示撤销。apply_plan 也采用这些规则，同一草案跨父请求不会重建已成功事件。

## 撤销

定位原操作，用 get_operation 取得 version 与 undo 支持信息。只有用户要求撤销时调用 undo_operation，传新 request_id、target_request_id、expected_operation_version。批量父操作不能整体撤销，可逐项处理成功子请求；先查看可撤销范围和用户意图。

支持普通日程/提醒的新建、修改、删除和偏好变更。对象又被修改时拒绝覆盖，重新解释差异，不能只换版本强行撤销。删除的恢复必须 allow_recreate=true，得到新 ID，并仅恢复支持字段；若用户要求完整附件等恢复，说明该工具做不到。

重复事项、例外、带参会者会议、富通知、容器删除、旧无快照或已压缩记录不支持。undo_started_by / undone_by 防止重复撤销，发生不确定结果先检查对应撤销请求，不能换请求 ID 再恢复一份。

## 冲突、变更与统计

- check_conflicts 覆盖指定范围和日历内的重复实例。排除 free / 取消事项，默认全天占用。缓冲表示最小间隔，返回的冲突也可能只是间隔不足。范围外的后续重复事项仍未检查。
- get_changes 首次返回基线；事件按时间范围，提醒覆盖选定列表的全部到期日期。按 next_page_token 仅传 page_token 读完冻结报告，最后一页才取得 cursor。下次使用相同范围、时区和容器参数加 cursor，limit 可改变。不使用 offset。7 天过期需重建基线，不能把失效解释为无变化。
- removed 仅表示离开范围，也可能是移动/改期/ID 改变，不能断言被删除。无稳定游标时明确只是新基线。快照是同步到本机的数据，非跨应用原子快照或实时订阅。
- get_statistics 的 scheduled_minutes_sum 是日程计划时长总和；timed_busy_minutes_union 合并重叠占用。全天按数量统计；均不等于实际工作时间。完成数按完成时间、到期数按到期日落入范围计算；逾期以 as_of（默认现在）计算。total_open / undated_open 是所选列表的全量状态。统计不能恢复已删除的历史完成记录。

冲突、规划与差异查询支持未来 10 年以内，单次范围最多 366 天。超过支持范围不要用不完整展开结果保证无冲突。

## 容器管理

list_sources 取得账户 ID；创建可指定 name、color 和 source_id，省略账户用系统默认容器所属账户。不要将创建目标账户与个人已保存的事项默认目标混淆。

修改/删除前通过 list_calendars / list_reminder_lists 读取当前容器版本。同名不同账户需消歧。删除需 delete_contents=true，覆盖整个容器及所有内容，包含查询范围外的重复/未来事项，而且不可撤销。用户已明确要求该完整范围时执行；若只是要删某些事项，改用事项删除，不扩大为容器删除。只读或不可修改的系统容器会拒绝操作。
