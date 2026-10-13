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
  builder: (dialogContext) => AlertDialog(
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

当前接入范围: 生产计划包取消/冲销、仓库成品实收、账户余额警戒线、销售稀缺让单、仓库销售出库备注、采购/委外订货改量。前两类及追加三类有确认/取消期间控制器仍可接收监听、退场结束后已释放的 Widget 回归；采购/委外沿用并加强原数量、权限和身份回归。
