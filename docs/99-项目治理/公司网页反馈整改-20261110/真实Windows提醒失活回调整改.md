# 真实 Windows 提醒失活回调整改

基准为冻结候选 `7b912287e53315228b469790ff066a9fab643e3c`。Root 的实际 Windows 引擎/本地 HTTP 运行失败，首因是 `OpportunisticDialogCoordinator.prioritize → notifyListeners → _ReminderState._priorityChanged → _queue → _current → ConsumerStatefulElement.read`，对已经 deactivate 的 element 进行 ancestor lookup。`mounted` 在临时失活时仍为真，不能作为 ref/context 可用的充分条件。后继 InheritedGoRouter/RenderLayoutBuilder 异常保留，不能倒置首因。

原始日志只读来源为 `D:/Projects/uten_imp_worktrees/feedback-remediate-20261110/evidence/final-7b912-windows-1/run.log`。完整实际字节复制在本独立树 `evidence/lifecycle-20261110/original-windows-7b-run.log`，哈希/来源/字节数见 `original-windows-sha256.json`。没有改宽度、等待门槛、业务 API、repository、session 或 Windows harness 来回避错误。

独立工作树 `D:/Projects/uten_imp_worktrees/feedback-lifecycle-20261110`，分支 `uimp/feedback-lifecycle-20261110`。沿用 frontend-design、原 Uten 主题与提醒流程，只调整回调生命周期与调度。

## 反例与公共修复

使用真实 `ServerUpdatePopupGate`（GlobalKey）、`ReviewPendingLoginGate` 和 `OpportunisticDialogCoordinator`：LayoutBuilder 宽900的 Row 改成窄500的 Column，先挂登录检查 gate，再重挂原提醒。修前最小 Widget VM 用例退出 1，准确得到 `Looking up a deactivated widget's ancestor is unsafe`，见 `baseline-deactivated-reminder.log`；它不是实际 Windows 通过记录。

`_ReminderState` 在 deactivate 时解除协调器监听并停止本地 timer，在 activate 时绑定当前 provider scope；所有 ref 读取先核对 attached。附件代际阻止失活前在途 status 在重新挂接后发布，即使业务 owner 相同也先退休原响应。没有取消共享 owner 的请求、改变服务器授权或把旧响应当新查询结果。

协调器的 blocker 集合与 opportunity.interrupted 仍立即更新。提醒、通知/审核、庆典、再认证、客户端下载/更新共用的 UI 通知在当前同步树更新完成后的 microtask 统一发送，避免 initState/dispose 内同步调用另一个 UI 的回调。退役后取消排队通知；晚注册回放只通知仍登记的那次 listener，且不与已经排队的全体通知重复。

## 证据与限制

| 验证组 | 结果 |
| --- | --- |
| Root 实际 Windows 7b 原运行 | 失败原件保持，首因完整栈在原日志1–79行。 |
| 最小原例 Widget VM | 修前 exit1；真实三种 gate/coordinator，未替换它们。 |
| 首轮相关5文件 | 73项通过，exit0；分析3文件0问题。 |
| 最终相关6文件 | `fixed-gates-2.log` 80项通过，exit0；含 layout 内登录 priority 关闭其可选 route、同 owner 重挂后旧 status 不发布、移除晚监听不回放、原权限/后台/暂缓/确认与再认证、通知/下载/倒计时等合法对照。 |
| 最终定向分析 | `analyze-2.log`，3文件，exit0，无问题。 |
| SDK/依赖/源码边界 | 私有 Flutter tool、私有 TMP；保护 SDK 字节核对不变；pubspec/lock 无改动；产品仅协调器与服务器提醒 gate。 |

这些为真实控件/路由的 Widget VM，服务器 status、通知及下载测试沿用既有受控 repository。不能写成真实 Windows 重跑通过，也不能解释尚未独立复现的 Web toolbar/overflow RenderLayoutBuilder 变异；该 Web 场景由并行任务单独复核。

整合后由 Root 固定新候选，从新 tag/private windows-runtime 重建实际 Windows 引擎，经真实 SessionNotifier 登录与本地 HTTP 再跑原 smoke。7b 原轮 Java/SQL/升级验证继续自然结束，不能因纯前端修复取消、覆盖或把后续 HEAD 冒作7b。
