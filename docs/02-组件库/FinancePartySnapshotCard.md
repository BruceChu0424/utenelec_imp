# FinancePartySnapshotCard(往来单位财务快照卡)与金额带币种显示

> 源码：
> - 卡片：`lib/features/finance/widgets/finance_party_snapshot_card.dart`(财务模块组件，2026-09-27 引入)
> - 数据模型与显示函数：`lib/shared/models/party_open_balance.dart`(销售、财务两个模块都用，所以放 shared)
> - 金额显示函数：`lib/shared/formatters/money_display.dart`
>
> 关联：[ADR-128 往来余额按单据币种显示与信用口径统一](../99-决策记录-ADR/ADR-128-往来余额按单据币种显示与信用口径统一.md)、[ADR-112 金额十进制原文](../99-决策记录-ADR/ADR-112-金额口径统一与资金过账单一入口.md)、[销售订单财务审核页](../03-页面/销售订单财务审核页.md)、[客户零星发货与出货财务审核](../03-页面/客户零星发货与出货财务审核.md)

## 一、为什么要有它

以前销售订单财务审核、出货财审、采购/委外订货审批三张审核页各写一张「财务快照卡」，各带一份私有的 `_money`、`_currencyLabel`，而且余额只有本币：美金订单旁边显示「客户应收 人民币 -1400」，看不出还差多少。

ADR-128 起，服务端只算一次(`PartyOpenBalanceView`)，前端三张页共用这一张卡、一个模型、一组显示函数，页面不再自己拼「币种 金额」。

## 二、金额显示函数(`money_display.dart`)

| 函数 | 作用 |
|---|---|
| `financeMoneyText(raw)` | 金额原文显示：至少 2 位小数、去掉多余的 0，不经过 double、不四舍五入；空值显示「—」，不是数字的原文原样返回 |
| `financeCurrencyText({name, code, fallback})` | 币种显示名：主档名称优先，缺名称时退回可读代码(`USD`)，`001/002` 这类旧数字编号一律不显示，都没有时用 `fallback`(默认「原币」) |
| `financeMoneyWithCurrency(amount, {currencyName, currencyCode, fallback})` | 「币种 金额」，如「美金 12000.00」；没有金额时只显示「—」，不单挂一个币种名 |

规则：凡是单据旁边、列表格子里要写「币种 金额」的地方都用 `financeMoneyWithCurrency`，禁止再手拼 `'$currency ${amount}'`。已收口的地方：销售订单财务确认列表的订单金额、订货审批列表的订货金额、出货审核列表的出货金额、订单资金状态卡各格、委外损耗索赔抵销弹窗的「未付」、供应商贷项应用面板的「可用余额」、三张审核页的本单金额与合计金额、IQC 不合格退回/贷项的原币金额(`originalAmountLabel`；本币金额走 `localAmountLabel` 只写金额，不挂单据币种)。

## 三、数据模型(`party_open_balance.dart`)

`PartyOpenBalance.fromJson(json)`：服务端没给(或不是对象)时返回 `null`，页面显示「—」，不猜 0。字段与服务端 `PartyOpenBalanceView` 一一对应，金额都是十进制原文字符串：

| 字段 | 含义 |
|---|---|
| `currencyName` | 单据币种 |
| `openOriginal` / `creditOriginal` / `netOriginal` | 单据币种下的应收(应付)未结、可用预收(可抵预付与贷项)、还差多少 = open − credit |
| `otherCurrencies` | 同一往来单位其它币种的余额，各用自己的币种，不换算、不相加 |
| `openBookLocal` | 全部币种正式应收(应付)的账面本币毛额，不扣预收；额度只和它比 |
| `unverifiedLocal` / `unverifiedCount` | 原币无法核实的历史余额(只有本币可信) |
| `creditLimitLocal` / `overLimitLocal` / `overCredit` | 比较用的额度(信用额度或铺底额，未设置为 null)、超出额度(可为负)、是否超额(服务端判定) |

显示函数(`PartyBalanceSide.customer` / `supplier` 决定文案)：

| 函数 | 例子 |
|---|---|
| `headline(side)` | 「美金 12000.00」；负数时客户写「预收有余 美金 200.00」，供应商写「可抵有余 人民币 200.00」(里面可能是预付，也可能是退货或索赔贷项) |
| `openText` / `creditText` | 「美金 500.00」 |
| `baseMoneyText(amount)` | 按本位币显示本币金额：「人民币 3500.00」 |
| `otherCurrenciesText(side)` | 「另有 人民币 30000.00、预收有余 港币 500.00」 |
| `unverifiedText(side)` | 「另有历史应收 人民币 1200.00 原币未核实」 |
| `footnote(side)` | 上面两句用「；」连起来；都没有时为 null |

## 四、卡片 API

```dart
FinancePartySnapshotCard(
  title: '客户财务快照 · 远硕智能(C001)',
  balance: review.clientBalance,            // PartyOpenBalance?
  side: PartyBalanceSide.customer,          // 供应商传 supplier
  leading: [FinanceSnapshotMetric('本单金额', '美金 144000.00', emphasis: true, danger: true)],
  limitLabel: '信用额度',                     // 出货财审传「铺底额」；订货审批不传(不比额度)
  overLimitWarning: '该客户全部币种应收(折本币，不扣预收)已超信用额度，请谨慎确认',
  trailing: [FinanceSnapshotMetric('铺底额', '人民币 2000.00')],
  footer: [/* 页面专属区块，如出货记账汇率区 */],
  note: '一行灰字说明',
)
```

卡片按顺序排格子(`UtenFormGrid`，窄屏自动一列)：

1. `leading`(页面自己的格子，如本单金额、结账方式、参考汇率)；
2. 余额三格：客户「应收未收 / 可用预收 / 还差多少」，供应商「应付未付 / 可抵预付/贷项 / 还差多少」，都写成「币种 金额」；
3. 给了 `limitLabel` 时再加三格：「全部币种应收(折本币)」、额度(未设置显示「未设置」)、「超出 + 额度名」(只有设置了额度才出)；超额时前后两格标红；
4. `trailing`；

格子下方：其它币种与原币未核实的补充说明(`footnote`)、超额横幅(只在给了 `limitLabel` 且服务端判定超额、页面也给了 `overLimitWarning` 时出现)、`footer`、`note`。

卡片不重算任何金额，也不自己判断是否超额。

## 五、使用方

| 页面 | 余额字段 | 额度 |
|---|---|---|
| 销售订单财务审核详情 `finance_sales_order_review_page.dart` | `clientBalance` | 信用额度(出横幅)；铺底额作为 `trailing` 格显示 |
| 出货财审详情 `finance_sales_shipment_audit_review_page.dart` | `clientBalance` | 铺底额(只标红，不出横幅)；记账汇率区走 `footer` |
| 采购/委外订货审批详情 `finance_procurement_approval_review_page.dart` | `supplierBalance` | 不比额度 |

销售订单财务确认列表不用卡片，「客户应收」格直接用 `headline`，补充说明(其它币种、原币未核实、超信用)放进格内提示，格子保持单行(全站表格单行口径)。

## 六、测试

- `test/shared/models/party_open_balance_test.dart`：解析、正负文案、其它币种与原币未核实、缺字段不猜 0、`financeMoneyWithCurrency` 不显示旧编号。
- `test/features/finance/finance_party_snapshot_card_test.dart`：客户卡超额标红与横幅、供应商卡不比额度、额度未设置、缺视图显示横线。
- 页面测试：`finance_sales_order_confirmation_page_test.dart`、`finance_sales_shipment_audit_review_page_test.dart`、`finance_procurement_approval_review_page_test.dart`、`finance_procurement_approval_tasks_page_test.dart`、`sales_order_money_summary_card_test.dart`、`sales_shipment_task_workbench_test.dart`。
