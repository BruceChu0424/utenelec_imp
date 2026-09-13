# UtenBusyOverlay

「点了按钮在跑长任务」的全屏居中加载遮罩（2026-09-12 新组件，同日按用户口径修订视觉）。

## 用法

```dart
// 挂哪都行（body Stack、AbsorbPointer 内、Positioned.fill 包着都无害）：
if (_saving)
  const UtenBusyOverlay(title: '正在批量入库', description: '按收货单分组织整批同事务提交'),
```

- `title` 必填一句话；`description` 可选（讲清在做什么、别做什么）；
- `semanticsKey` 供宿主测试锁定（如物料分析的 `material-analysis-plan-submission-progress`）。

## 行为契约

| 语义 | 约定 |
|---|---|
| 全屏蒙版 | 组件把画面送进 **root Overlay**：宿主 Stack 只覆盖内容区（宽屏右半）也照样铺满整屏、卡片居中**屏幕**正中；本体在宿主树里渲染 `SizedBox.shrink` |
| 蒙版色 | 页面背景色向中灰轻掺（浅色 12%/深色 16%）再 82% 不透明——「和背景差不多但偏灰点」，不用半透明黑 scrim |
| 挂载时机 | 帧后插浮层（构建期插会 markNeedsBuild during build）；宿主被路由压栈（TickerMode=false）不挂，回前台（didChangeDependencies）再评估——避免宿主页+分桶页各挂一张同 key 卡片 |
| 撤下时机 | **只跟随网络调用本身**：结果弹层展示期间必须已撤下，否则弹层背后转圈、widget test 的 pumpAndSettle 永不落定（物料分析 `planSubmissionProgress` 同款教训；挂载点必须在数量确认弹窗收口后的纯网络段） |
| 拦截 | `ModalBarrier(dismissible: false)` 吃掉蒙版层点击，不可关闭 |

## 接入方

- 物料分析：`_planSubmissionOverlay`（下达车间，delegate 到本组件，语义 key 保留）、`bucketActionBusyMessage`（下达采购/委外，挂 `_notifyRoute` 分块段）
- 品质：批量审批页、FQC 检查单办理页、IQC 单张处置页（提交报告）
- 仓库：IQC 批量入库页、产成品批量全量点收页、普通出库审核（stock_doc 详情）
