# UtenHistoryTimeFilter

> 源码：`lib/components/layout/uten_history_time_filter.dart`
> 创建：2026-09-03（「历史记录/历史单据」分段的标准时间门控行）
> 相关：[UtenFilterToolbar](UtenFilterToolbar.md)、[UtenDialog](UtenDialog.md)

## 一、定位

2026-09-03 起全平台「历史记录 / 历史单据」范式的时间门控组件：分类分段末尾的
历史段被选中后，内容区顶部渲染本组件——

- **两个胶囊**：「时间段」（点开居中的紧凑日期范围弹窗
  `showUtenDateRangePicker`，最大 520 宽、内容自适应高度，2026-10-24 起全站
  唯一形态：UtenRadius.dialog 圆角、右上角关闭、右下角「确定」主按钮；
  选中后胶囊显示起止日期，可反复点按调整范围）与「全部」（不限时间全量
  加载）；样式与 UtenFilterToolbar 的分段胶囊同构（StadiumBorder、选中
  secondaryContainer）；
- **默认近三个月**（2026-10-24 用户口径；2026-10-04 曾改为默认「全部」，更早
  为默认不选）：页面进入历史段时以 `UtenHistoryTimeValue.lastThreeMonths()`
  作为初始值（今天往前推三个自然月、含今天），历史数据较多的页面不再一进来
  就全量加载，需要更早的数据再点「全部」或另选时间段；`UtenHistoryTimePlaceholder`
  与「none 不发请求」护栏保留为值形态（`isNone`），但不是页面默认；
- **单选互斥**：选「时间段」即取消「全部」，选「全部」即清空时间段；
- 值对象 `UtenHistoryTimeValue`（none / all / range(DateTimeRange) +
  `lastThreeMonths()` 工厂），不可回退到 none——避免误触把已加载的历史列表
  清回占位态；
- 日期一律走 `ChinaDateTime`（墙上时间，不受设备时区影响）；调用方用
  `ChinaDateTime.formatDate(range.start/end)` 生成 `dateFrom/dateTo`（yyyy-MM-dd）。

## 二、用法

```dart
// 页面状态默认近三个月；切段时进入历史段重置回默认，非历史段回 all() 占位。
UtenHistoryTimeValue _historyTime = UtenHistoryTimeValue.lastThreeMonths();
UtenHistoryTimeFilter(
  value: _historyTime,
  onChanged: (value) {
    setState(() => _historyTime = value);
    _reload(1);  // _shouldLoad 门控：isNone 时不发请求
  },
)
// 内容区：
// _seg == null                       → UtenFilterPlaceholder（未选分类）
// _seg.history && _historyTime.isNone → UtenHistoryTimePlaceholder（未选时间）
// 其余                                → 列表/表格
```

仓库任务中心的分段可复用包装容器 `WarehouseHistoryGate`
（`lib/features/warehouse/widgets/warehouse_history_gate.dart`）：时间行 +
占位/子树一体，子树按时间值自行下发 dateFrom/dateTo（挂载即用默认近三个月
构建）。

## 三、约定

- 后端接口需支持 `dateFrom/dateTo`（ISO 日期）才可接历史段；原生 SQL 判空
  一律 `CAST(:param AS date) IS NULL OR ...`（PG 42P18 坑）；
- 历史查询**不限状态**（翻旧账按时间，状态由分类行表达）；
- 历史段内换状态/表头筛选**保留已选时间**（ADR-180 历史保留原时间范围），
  只有离开再进入历史段才重置回默认近三个月；
- 时间行不放徽章；「全部」即不限时间，不是"全部状态"。
