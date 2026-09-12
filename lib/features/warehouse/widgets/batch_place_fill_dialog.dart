// 「批量设置库位号」弹窗：产成品登记页与采购到货登记页的右键批量动作共用。
//
// 控制器由弹窗自身持有并在其 dispose 时释放（不能在 showDialog 返回后立刻 dispose，
// 关闭动画期间 TextField 仍会重建）。返回 trim 后的库位号；取消返回 null。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<String?> showBatchPlaceFillDialog(
  BuildContext context, {
  required int rowCount,
  Key inputKey = const Key('production-finished-arrival-batch-place-input'),
  Key applyKey = const Key('production-finished-arrival-batch-place-apply'),
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _BatchPlaceFillDialog(
      rowCount: rowCount,
      inputKey: inputKey,
      applyKey: applyKey,
    ),
  );
}

class _BatchPlaceFillDialog extends StatefulWidget {
  const _BatchPlaceFillDialog({
    required this.rowCount,
    required this.inputKey,
    required this.applyKey,
  });

  final int rowCount;
  final Key inputKey;
  final Key applyKey;

  @override
  State<_BatchPlaceFillDialog> createState() => _BatchPlaceFillDialogState();
}

class _BatchPlaceFillDialogState extends State<_BatchPlaceFillDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('批量设置库位号(${widget.rowCount} 行)'),
      content: TextField(
        key: widget.inputKey,
        controller: _controller,
        autofocus: true,
        maxLength: 100,
        inputFormatters: [LengthLimitingTextInputFormatter(100)],
        decoration: const InputDecoration(
          labelText: '库位号',
          hintText: '应用到全部选中行',
          counterText: '',
        ),
        onSubmitted: (_) => Navigator.of(context).pop(_controller.text.trim()),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: widget.applyKey,
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('应用'),
        ),
      ],
    );
  }
}
