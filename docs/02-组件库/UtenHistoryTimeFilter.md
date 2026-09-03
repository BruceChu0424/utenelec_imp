# UtenHistoryTimeFilter

> 源码：`lib/components/layout/uten_history_time_filter.dart`
> 创建：2026-09-03（「历史记录/历史单据」分段的标准时间门控行）
> 相关：[UtenFilterToolbar](UtenFilterToolbar.md)

## 一、定位

2026-09-03 起全平台「历史记录 / 历史单据」范式的时间门控组件：分类分段末尾的
历史段被选中后，内容区顶部渲染本组件——

- **两个胶囊**：「时间段」（点开系统日期范围选择器，选中后显示起止日期，
  可反复点按调整范围）与「全部」（不限时间全量加载）；样式与
  UtenFilterToolbar 的分段胶囊同构（StadiumBorder、选中 secondaryContainer）；
- **默认不选**（`value = none`）：内容区应同时显示 `UtenHistoryTimePlaceholder`
  引导占位，且**页面不得发起数据请求**——历史数据量大，只有用户显式选择了
  时间段或「全部」后才加载；
- **单选互斥**：选「时间段」即取消「全部」，选「全部」即清空时间段；
- 值对象 `UtenHistoryTimeValue`（none / all / range(DateTimeRange)），不可回退到
  none——避免误触把已加载的历史列表清回占位态；
- 日期一律走 `ChinaDateTime`（墙上时间，不受设备时区影响）；调用方用
  `ChinaDateTime.formatDate(range.start/end)` 生成 `dateFrom/dateTo`（yyyy-MM-dd）。

## 二、用法

```dart
// 页面状态：UtenHistoryTimeValue _historyTime = const UtenHistoryTimeValue.none();
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
占位/子树一体，子树按时间值自行下发 dateFrom/dateTo。

## 三、约定

- 后端接口需支持 `dateFrom/dateTo`（ISO 日期）才可接历史段；原生 SQL 判空
  一律 `CAST(:param AS date) IS NULL OR ...`（PG 42P18 坑）；
- 历史查询**不限状态**（翻旧账按时间，状态由分类行表达）；
- 时间行不放徽章；「全部」即不限时间，不是"全部状态"。
