# UtenPagination

列表、表格、卡片网格及选择弹窗统一使用 `lib/components/layout/uten_pagination.dart`。默认设计技能为 `frontend-design`；本组件沿用货品资料的 Uten 主题、字体、圆角和工具条位置。

分页外观为 `‹ [当前页] / 总页数 ›`，不再展示“上一页 / 下一页”文字按钮。桌面箭头命中区为 32，图标为 24，页码框基础尺寸为 40 × 28；触控使用至少 48 的命中区。输入框随数字宽度增长，大字体随文字高度增长，受限宽度下依次改为纯页码计数或换行，避免缩小命中区。

```dart
UtenPagination(
  currentPage: page.page,
  totalPages: page.totalPages,
  busy: loading,
  onPageChanged: (target) => load(page: target),
)
```

| 参数 | 合同 |
| --- | --- |
| `currentPage` | 从 1 开始的当前阅读页，由调用方维护 |
| `totalPages` | 后端或完整本地集合确认的总页数；游标接口未知时传 `null`，显示 `/ ?` |
| `maxPage` | 游标模式下已知可访问的页码上限；用于限制输入，不作为总页数显示 |
| `onPageChanged` | 输入跳转和默认箭头共用的读请求入口 |
| `onPrevious` / `onNext` | 已有调用方的单步导航适配；仍受边界和 `busy` 限制 |
| `busy` | 同时禁用输入与箭头 |
| `controller` / `focusNode` | 仅供公共表格保留阅读页、滚动缓冲和全屏路由同步；普通调用方使用组件自持状态 |

回车提交页码：非法输入恢复当前页，越界输入限制到合法范围，不重复请求当前页。未提交输入在失焦时恢复当前阅读页；外部切页后同步页码。组件只呈现和发出切页意图，不负责查询、缓存、权限、请求代次或选择状态。

`MasterDataTableView`、`UtenPickerPageControls`、`UtenGridPager` 均调用该组件，不再维护独立分页外观。列表宿主保留原有筛选、排序、跨页选择、阅读位置、回顶和身份隔离。

修改历史使用原有游标读取和缓存。尚未到达末页时显示 `/ ?`，跳转只允许到达已知页；到达末页后显示确认的总页数。筛选、刷新和身份变化重新建立边界。本机草稿历史沿用原有游标栈，可直接返回栈内任一页。

本次完整接入清单、源码差异和验证记录位于 `output/pagination-unification-20261028/`。日期切换、流程步骤、PDF 文档页码和打印纸面页码保留其原有语义，不属于数据列表分页。
