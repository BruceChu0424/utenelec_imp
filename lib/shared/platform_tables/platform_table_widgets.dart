import 'package:flutter/material.dart';
import 'platform_table_controller.dart';
import 'platform_table_models.dart';
import 'platform_table_picker.dart';

/// One cell interaction for every platform table, including fullscreen views.
class PlatformColumnValue<T> extends StatelessWidget {
  const PlatformColumnValue({
    super.key,
    required this.controller,
    required this.row,
    required this.column,
  });
  final PlatformTableController<T> controller;
  final T row;
  final PlatformColumnDefinition column;
  @override
  Widget build(BuildContext context) {
    final signals = <Listenable>[
      ...?controller.binding?.factListenablesOf?.call(row),
      ...?controller.fallbackFactListenablesOf?.call(row),
      ?controller.draftOf?.call(row),
    ];
    if (column.calculated && signals.isNotEmpty) {
      return ListenableBuilder(
        listenable: Listenable.merge(signals),
        builder: (context, _) => _buildValue(context),
      );
    }
    return _buildValue(context);
  }

  Widget _buildValue(BuildContext context) {
    final value = controller.value(row, column);
    final editable = controller.canEdit(row, column);
    final text = Text(
      value?.isNotEmpty == true ? value! : '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: column.numeric ? TextAlign.right : TextAlign.left,
    );
    final error =
        controller.cell(row, column.id)?.error ??
        (column.calculated &&
                value == null &&
                !(controller.historical &&
                    controller.capabilities?.supportsValues != false &&
                    controller.cell(row, column.id) == null)
            ? '所需数值为空、不可见，或计算不能得到精确有限小数'
            : null);
    if (error != null) {
      return Tooltip(
        message: error,
        child: Text(
          '计算不可用',
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      );
    }
    if (!editable) return text;
    return Semantics(
      button: true,
      label: '编辑${column.name}',
      child: InkWell(
        onTap: () => showPlatformCellEditor(context, controller, row, column),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              Expanded(child: text),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined, size: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class PlatformTableStatus extends StatelessWidget {
  const PlatformTableStatus({
    super.key,
    required this.error,
    required this.retry,
  });
  final String? error;
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => error == null
      ? const SizedBox.shrink()
      : TextButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh_rounded),
          label: Tooltip(message: error!, child: const Text('扩展字段读取失败，重试')),
        );
}
