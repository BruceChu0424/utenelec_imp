# UtenDialog

源码: [`lib/components/feedback/uten_dialog.dart`](../../lib/components/feedback/uten_dialog.dart)。

`UtenDialog.show` 提供已有的统一确认样式。需要定制输入布局时，沿用业务弹窗的 builder，并通过 `UtenDialog.showAndWaitForExit<T>` 等待弹层完全退出后再释放外部控制器。

## 外部控制器的生命周期

Flutter `showDialog` 返回的结果在 `Navigator.pop` 时完成，此时退场动画中的 `TextField` 仍然挂载。外部创建的 `TextEditingController` 只有在路由 `completed` 之后才能释放。`showAndWaitForExit` 包装原 Material `showDialog`，保留其 root navigator、barrier、主题、媒体信息、safe area 和 route settings 默认行为；它从实际 builder 上捕获 `ModalRoute` 并等待 `completed`，没有另建一套 DialogRoute 协议。

- 数量、原因等业务输入在确认按钮中读取并作为类型化结果返回，确认后不再读取可变控制器来组装命令。
- 调用方等待 helper 后释放控制器，再校验页面、资源和身份是否仍属于本次动作，才可执行命令。
- 属于弹窗自身 `State` 的控制器继续在该 State 的 `dispose` 中释放。
- 不用固定延迟估计动画何时结束；本次采购/委外改量的 300ms 近似延迟已改为实际路由完成。

```dart
final controller = TextEditingController();
final result = await UtenDialog.showAndWaitForExit<String>(
  context,
  builder: (dialogContext) => UtenAlertDialog(
    content: TextField(controller: controller),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(dialogContext, controller.text),
        child: const Text('确认'),
      ),
    ],
  ),
);
controller.dispose();
```

当前外置控制器审计覆盖42处直接创建、34个所有者函数：原7个已使用路由完成等待的函数保留，另27个迁入统一等待。覆盖表格粘贴数量/追加行、员工电话、采购退货、车间物料更正/取消、访客审批、委外短交决定、盘点审核、销售改量/驳回、薪资审核、财务订单确认/资产过账/委外损失索赔/供应商结算、岗位编辑及往来单位联系人/地址/活动，并补齐通过`UtenDialog.show`借用局部控制器的保安拉黑和物料整批撤回；原生产计划包取消/冲销、仓库成品实收、账户余额警戒线、销售稀缺让单、仓库销售出库备注、采购/委外订货改量继续采用同一协议。弹窗自身State拥有的控制器仍在State.dispose释放。

需要统一确认样式且正文借用局部控制器时，`UtenDialog.show(waitForExit: true, onPopped: ...)`复用等待协议；`onPopped`只冻结输入，caller用finally释放控制器。普通`show`默认时序保留。全仓`show`正文直接借用控制器的4点中，上述2点属于局部所有者；另外盘点会话/行内盘点的理由由页面State持有，保持State的原销毁边界。

`showAndWaitForExit`从入口直到`route.completed`持有调用页面context的弱引用租约。同一context在弹窗尚未显示或退场动画期间再次调用会得到取消结果null，不运行第二个builder或onPopped，也不释放第一个调用的租约；不同context互不阻塞。确认、取消、构造异常和快照异常后都释放租约，允许再次打开。等待退场属于确认期，不把它显示成API请求忙态；命令仍在调用方完成身份、权限与数量校验后执行。真实销售改量和发货驳回按钮的退场指针回归验证每次仅打开一个确认窗、提交一个命令。


## 2026-10-13 统一尺寸与滚动

- `UtenDialog.show`使用480设计宽；`UtenAlertDialog`是原生AlertDialog的统一适配壳，普通上限560，默认可滚正文，保留原生焦点、语义、动作overflow和返回值。
- `UtenDialogFrame`承载大型业务面板，默认上限960，整窗高度最大为扣除键盘/安全区后的可用高85%。它不替代业务内部有界表格的滚动或确认状态。
- 小宽内距12；画布小于240时外侧水平边距4，避免200%手机把正文和按钮挤没。很短窗口中动作区也放不下时整体滚动，正文和动作都可达；通常窗口按钮保持在正文滚动区之外。
- 正文和标题使用同一NotoSansSC字体体系；正文16、标题18，系统非线性文字策略不丢失。外框圆角20；控制器与业务身份不随布局切换重建。
- 正文已有ListView/表格/ScrollView时显式 `scrollable:false`并维持有界高度；其他长表单使用默认正文滚动。
- `showAndWaitForExit`的 `onPopped`仅用来在pop时快照确认值，随后才等待退出；即使快照抛错也必须等待completed再释放外置controller。命令、权限与身份检查仍在调用方执行。

验证包含320手机至桌面、横屏低高、85%～200%、系统文字与应用倍率叠加、键盘、确认/取消、数量全文与真实点击坐标。格式与组件采用护栏：[ui_geometry_contract_test.dart](../../test/core/ui_geometry_contract_test.dart)。

多按钮选择弹窗在可用高度不足以容纳堆叠操作及最小正文时，整体进入滚动模式；标准空间仍保持操作区固定。报价模板使用共享弹窗的一处正文滚动，避免内嵌惰性视口被长操作区挤成零高度。

长弹窗明确显示自身滚动条，提示有更多内容；内容子树继续使用原滚动配置，业务表格不叠加自动滚动条。矮窗整窗滚动模式使用完整设计宽度，滚动条贴在弹窗边缘。验证夹具使用实际UtenScrollBehavior而非默认Windows行为。
