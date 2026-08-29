# UtenReviewerResponsibilityNotice

## 一、用途

`UtenReviewerResponsibilityNotice` 用于会形成正式审核、审批、通过或驳回事实的确认面，固定显示：

- 红色警示图标与文字 `审核员：姓名(工号)`；
- “确认后系统将以此登录员工记录审核责任”的责任说明；
- 读屏可识别的完整审核员与责任语义。

对应实现：`lib/components/feedback/uten_reviewer_responsibility_notice.dart`。普通审核确认优先调用
`showUtenReviewerConfirmDialog`，责任提示始终位于业务影响说明上方。

## 二、身份与审计边界

- 姓名、工号只从当前 `sessionProvider.user` 读取，用于让点击者在确认前辨认自己的责任身份。
- 请求体不得携带可由客户端伪造的审核员 ID 或姓名。
- 实际审核员以服务端安全上下文中的当前员工 UUID 为权威，并写入单据 `approver_id`、决定事件
  `decided_by_*`、IQC 追加事件 `actor_employee_id` 或相应审计字段。
- 采购/委外订货采用财务审核组共享队列；任务被处理前没有指定个人审核员。责任提示显示当前实际
  点击“通过/退回”的员工，不能读取历史 `assigneeName` 冒充本次审核人。

## 三、适用与禁止

适用：审核、财务确认、审批通过、审批驳回、IQC 合格/不合格、批量审核、审核并启用。

禁止：保存、提交审核、删除、红冲、发布、过账、拣货、普通业务确认。这些动作的点击者不是审核员，
不得为了视觉统一误标责任身份。

## 四、交互要求

- 使用 `ColorScheme.error/errorContainer` 语义色，同时保留图标和完整文字，不能只靠红色传意。
- 提示位于确认按钮之前；窄屏允许换行，不截断姓名或工号。
- 审核动作异步执行期间按钮禁用并显示加载反馈；服务端仍须独立校验权限、对象状态、审核资格与并发版本。
