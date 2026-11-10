# 第一张：核对页改量与库存抵扣回归

候选源码：UI `2aef4d1d2`、后端 `02b3c080c`，基线 `86dffb9db`。本记录仅覆盖第一张及相邻同类下单链。

## 原始反馈与已证实事实

原话：“下单时改动物料的数量，导致无法下单”。图中 V6 外箱需要 50、可用 18.1517、还缺 31.8483、下单填写 500，方式为“全部下单采购”。截图只显示“同料合并下达”总失败，没有实际拒绝原因。

修复前的当前主线，在合成真库中已能以 `ORDER_ALL` 对需求 50 下采购/委外 500。因此不能仅凭这张图唯一确定公司原单当时的权限、来源或版本，也不能把下面的“先用可用数量”缺陷说成图中足额下单的唯一原因。历史主线已有 `74c98b08f`、`2d81c571e`、`9a73f9584` 等行级方式、库存采用和到货归属变更；未据此推定公司已部署。

本次确认并修复四处问题：

1. 最终结果汇总丢掉每段的 `note`，把服务端的真实拒绝原因遮住。现在在同一结果中保留权限、来源、精度或预览校验原因。
2. 核对页为下单临时生成的汇总草稿，在明确未写入后仍锁住原行。现在只释放本轮自动创建、结果确定的产品流临时草稿；保留原数量和勾选，可原地改数继续。未知提交、原幂等键以及用户已有的手工汇总草稿继续保留。
3. Flutter 把覆盖总量 500 直接与新增下单份额比较，合法扣除已覆盖 18.1517 后的 481.8483 会被误拒。现在按服务端返回的原行精确事实核验新增量，原请求仍保留 500，错误份额仍拒绝。
4. 服务端汇总命令在实物认领之后，仍使用认领前的行快照转换覆盖总量。公共现货原本预分配给兄弟来源时，选中行新取得现货却未相应减少新单。现在与普通通知入口一致，按本次实际认领后的快照转换；已预分配到本行的现货不会再次扣减。复用原有 `refresh/detail`，没有增加完整读取次数。

## 公共入口与适用调用方

| 入口 | 本次处理 |
| --- | --- |
| `_MaterialAggregateTableController._performPreview` | 所有物料汇总预览共用精确覆盖口径校验 |
| `_MaterialAggregateSubmission` | 所有依赖分轮下单共用确定拒绝/未知提交边界 |
| `_submitMaterialTableRows` / `_reportMaterialTableSubmit` | 原产品树、核对页、补下层物料及混合根/组件提交共用结果汇总 |
| `_PreparationOrderPage` | 车间、采购、委外三个准备桶共用核对页；未新增另一套编辑、等待或提交逻辑 |
| `/api/production/material-analyses/{id}/aggregate-orders/submit` | 采购、委外、自制汇总共用认领后的数量归一化；单来源、多个来源及依赖轮次保留原来源证明 |
| 普通 `notifySupply` | 已在实物认领后重取权威行，本次采用同样时序，没有重复改写 |

Web 与现有 Flutter 桌面端使用同一 Dart 控制器及同一服务端写入口。WPF 的物料分析/核对下单仍是未迁移业务（例如 `W7-BIZ-095` 为 todo、nativeTargets 为空），没有用本次 Flutter 或服务端回归标记原生业务完成。

超量权限、原来源归属、服务端数量权威、固定安全补库量、幂等回执和写入上限均沿用原合同。`ORDER_ALL` 仍按填入数量新下单；`AVAILABLE_THEN_ORDER` 才使用可用量抵扣。未新增业务写入口、迁移或正式包。

## 验证与证据

- [原最终结果吞掉原因的失败](ui-summary-before.txt)。
- [明确拒绝后原行仍被临时草稿锁定的失败](ui-source-lock-before.txt)。
- [恢复旧总量比较口径的反证](ui-coverage-contract-before.txt)：仅恢复旧比较条件后，合法新增 481.8483 被拒，写请求为 0；其余修复保持不变。
- [核对页完整 27 例](ui-order-regression-27.txt)：包括父子数量联动、撤选、追加、取消、原地改量重试和未知提交保留。
- [最终专项 5 例](ui-focused-5.txt)：另含 `ORDER_ALL` 50 私有需求 + 450 公共备货，合法扣现货、错误份额拒绝、原因可见且改 499 再成功、未知提交冻结。与 27 例有重叠，不能相加为 32 个独立用例。
- [静态检查](analyze-final.txt)：0 问题。
- [原真库失败](db-before.txt)：修复前采购/委外 `ORDER_ALL` 成功，扣可用数量的订单断言失败。

最终冻结后端回归共 48 例，全部通过、无失败/错误/跳过：

| 回归 | 结果与证据 |
| --- | --- |
| 独立真库 4 例 | [4/4](db-final.txt)：采购/委外 `ORDER_ALL` 下 500；采购扣现货选择已预分配与未预分配来源，两者实际新单均为 481.8483、公共份均为 450，重放同一命令不重复写入，实物总量保持 18.1517 |
| 数量兼容 | [3/3](quantity-compatibility-final.txt) |
| 汇总预览 | [41/41](aggregate-preview-final.txt) |

命令：`UTEN_RUN_DB_TESTS=true`，`mvn -q -Duten.build.directory=target-company-material-final -Dtest=CompanyMaterialOrderQuantityEndToEndTest,MaterialOrderQuantityCompatibilityTest,AggregateMaterialOrderPreviewServiceTest test`，退出码 0。

独立 Testcontainers PostgreSQL 已实际执行完整 1067 个迁移至 V1128；原始完整命令日志保留在本工作树 `server/company-material-*.log`。证据不代表公司原单复跑、浏览器真库交互、Win7 真机验收、全量 CI 或发布验收。
