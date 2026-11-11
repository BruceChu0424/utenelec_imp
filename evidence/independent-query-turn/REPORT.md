# 独立复核：事件轮缓存遮蔽同轮查询退休

本组审查对象为Root合并候选 `8c2116d9f65342f4a3d8c486aadb5aa42b79a69f`。独立树通过正常merge保留前述Tooltip原件，生产路径lib/server/clients/pubspec与该候选逐Git diff相同；执行HEAD如实见source-comparison.json和原工具receipt，不把它改写成Root SHA。没有改任何生产代码、main、原audit或浏览器。

## 可证实的公共API反例

夹具与主线scoped_owner_check_budget_test同型：一个ConsumerState使用ScopedPagedReadViewMixin，调用readScopedPage时提供必需query/currentQuery，不传可选isCurrent。源为立即完成的合法单页Future，使用真实事件循环，不靠假timer时钟制造结果。

同一个事件轮执行：

```dart
final pending = state.read(); // 捕获查询A
state.query = 'B';            // 必需currentQuery现在返回B
await pending;               // 旧A结果必须退休，而不能返回给消费页面
```

当前合并mixin的queryAnswerValid在Timer.zero前保持true，跨Future微任务继续复用旧深比较。mounted/owner代际未变时，必需的live query比较被遮蔽，旧A的PagedResult实际返回。

`private-flutter-independent-owner-turn-13.log`：**2通过/1失败/0跳过，退出1**。

- 不改查询：合法单页结果通过。
- 改查询并显式invalidate：明确退休通过。
- 只改变currentQuery：预期UiWorkCancelled，实际Future返回旧PagedResult，失败。

这证明公共读取API的查询退休保障退化，**未据此证明某个真实业务页面已经跨权限输出、错误写入或泄露**。具体页面可能还有独立request-generation/isCurrent防线；不能把这些调用方防线当成公共currentQuery参数可以失效的理由。

## 旧版本及相邻合法对照

从Git 4d45取得旧mixin复制到独立test库，仅把相对imports/exports重定位为package URI，算法正文逐行相同（source-comparison.json有断言和精确原blob）。同8c其余reader、同三项断言，旧mixin **3/3通过、退出0**，见original-15原日志。

首次original-14仅因复制时遗漏bare相对import而编译失败，未触及业务，原日志保留；修正imports后在新文件名/日志15重跑，没有改松断言或覆盖原件。

## 修复约束

应保留每行热路径的owner turn预算优化，不能直接用整份旧文件覆盖main。可在异步结果返回或逐prefix真正发布边界进行一次强制live query/epoch实核；普通连续逐行检查仍可复用本轮答案。修后至少独立重跑本三例和原owner预算、403、旧scope、确认写后退休、同query旧完整保留等对照。

本组仅为Flutter VM公共API实验，不冒称真实Web→PG或最终整体验收。生产修归Root/C；新候选出来后再独立复跑。
