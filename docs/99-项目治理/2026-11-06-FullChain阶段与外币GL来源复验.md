# FullChain 阶段与外币 GL 来源复验

本次只更新真实业务链测试驱动，服务端业务守卫、请求、写入上限、精度与客户端合同保持原样。生产品质数量文本问题另由 `70c2c6242` 修复；Stock 公共批次估值另由 `eb1b46510` 修复。

## 已确认根因

FullChain 测试配置关闭库存成本自动 polling，但旧串行驱动在上一业务动作提交后直接开始下一个动作。原 AR 发货单案的实际元数据证明：失败时原 revision 为 APPLYING，2 个 production tasks 尚待执行，12-node/3-key precision closure 未完成；随后只调用既有真实 worker，原 revision 成 FINAL、队列清空、closure 完成。原单案失败及其 exit 1 保留，没有重放业务写。

公共驱动现在在发货、全额点收入库、新报工和再次开账之前推进原已提交的成本阶段，使用原 45 秒 worker deadline。文档家庭使用两条固定 SELECT 的枚举，不拼接表名。并发 prefix 场景在比赛开始前完成先前阶段，在原先已确认完整 source-drift rollback 后、显式重试前推进第一动作提交的成本阶段；原 CONFLICT/“本次操作未生效”限定、真实锁等待、12/8/15 秒边界及数量/来源断言均未放宽。final-report 成本专项在首次入库与下一次真实 material settlement 之间同样完成前一阶段。

报工自身新产生的 pending work 仍留给相应用例观察；`withRefreshClaim` 的原 pending 事件、原批准人及后续无会话 worker 断言保持。

## 外币事实定位

原外币单案使用 `summary='收款汇兑损益'` 选择 GL 行。实际 authorityVersion=2 的已入账凭证已经保留正确借 4320、贷 AR4200、贷 FX120；FX 行 line_no=5、direction=-1，style UUID 与原收款冻结 `gl_fx_style_id` 完全一致。新 authority 分支按原收款摘要展示全部分录，旧专用摘要仅属于历史分支。

测试按原 receipt UUID、冻结 FX style UUID、已入账且未删除的原 voucher/entry 选唯一事实，并增加收益贷方断言。原 120、双币余额、明细回传、原币账户、反审与后继草稿及整凭证借贷平衡断言均保留；生产摘要没有改变。

## 验证与边界

| 范围 | 实际结果 |
| --- | --- |
| 原 243 FullChain 完整类 | 158 中 1 failure、16 errors；完整 XML 由本轮 CI artifact 核定。 |
| 第一版公共阶段驱动，原完整 158 | **154 通过、4 失败，0 skip/abort，exit 1**。剩余是品质整数文本、两个直接/并发成本阶段及摘要选择；原失败日志保留。 |
| v2 重点 5 案 | **5/5，0 skip/abort，native 0**，431.308 秒；品质完整登记/处置/撤回、AR 发货、final-report 重估及两组 prefix 双方向真实并发。 |
| 最终阶段驱动 + FX 身份定位，原重点 6 案 | **6/6，0 skip/abort，native 0**，559.038 秒；新增外币原完整同案，包含其原回传/反审后半段。 |

最终整体 158 与同一审核提交的远端完整 CI 仍需自然完成，不能由上述不同来源的分范围结果合并宣称全项目通过。

证据保留在 `D:/Projects/uten_imp_worktrees/ci-stock-batch-20261106/build/ci-stock-batch-20261106/`：`closure-diagnostic/` 为原失败及真实 worker 前后态；`world-driver/` 为原完整 158 的第一版阶段驱动；`world-v2/` 为重点 5；`fx-diagnostic/entries.json` 为匿名原单实际 GL 元数据；`world-final/` 为最终源码与重点 6 的原生结果。各次源码副本、旧失败及实际编译日志保留，所选源码 `javac -Werror` 通过。
