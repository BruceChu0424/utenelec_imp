// UtenMultiValueCell - 表格多值单元格（2026-10-29 全站统一口径）。
//
// 源头是仓库任务中心「生产工单」列的用户口径：一格聚合多个单号/名称时，
// 不能把表格撑得太长——格内最多显示首个值 +「等 N 个」，点击弹窗列全部，
// 可跳详情的值在弹窗内逐条提供入口（参照车间任务物料摘要格行为）。
//
// 分工：本组件只管屏幕上的单元格显示与弹窗；导出/打印/列筛选/排序等口径
// 仍由调用方的 value/textOf 提供全量串，不经过本组件。
import 'package:flutter/material.dart';

import '../buttons/uten_button.dart';
import '../feedback/uten_dialog.dart';
import 'uten_table_cell_action.dart';

/// 多值截断摘要：`首个 等 N 个`（N 超过 [maxShown] 时），否则原样连接。
/// 供与 [UtenMultiValueCell] 同口径的纯文本场景（如保留既有整格跳转的列）复用。
String utenMultiValueSummaryOf(List<String> values, {int maxShown = 1}) {
  if (values.length <= maxShown) return values.join('、');
  return '${values.take(maxShown).join('、')} 等 ${values.length} 个';
}

/// 表格多值单元格：格内 1 个 +「等 N 个」，点击弹窗列全部，可选逐条「查看详情」。
class UtenMultiValueCell extends StatelessWidget {
  const UtenMultiValueCell({
    super.key,
    required this.values,
    this.title,
    this.emptyText = '—',
    this.maxShown = 1,
    this.detailLabel = '查看详情',
    this.onDetail,
    this.detailAvailableOf,
    this.enabled = true,
  });

  /// 去重后的全部值（显示、Tooltip 与弹窗同源）。
  final List<String> values;

  /// 弹窗标题；null 时用「共 N 项」。
  final String? title;

  final String emptyText;

  /// 格内最多显示几个值（默认 1，2026-10-29 用户口径）。
  final int maxShown;

  final String detailLabel;

  /// 按值打开详情（如 push 对应单据路由）；null 时弹窗不提供详情入口。
  final void Function(String value)? onDetail;

  /// 按值判定是否具备详情入口（默认全部可跳）；仅 [onDetail] 非空时生效。
  final bool Function(String value)? detailAvailableOf;

  /// false 时退化为纯文本（不弹窗），如宿主行处于办理锁定。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final distinct = values.where((value) => value.isNotEmpty).toSet().toList();
    if (distinct.isEmpty) {
      return Text(
        emptyText,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      );
    }
    return UtenTableCellAction(
      label: utenMultiValueSummaryOf(distinct, maxShown: maxShown),
      tooltip: distinct.join('、'),
      onPressed: enabled ? () => _openList(context, distinct) : null,
    );
  }

  Future<void> _openList(BuildContext context, List<String> distinct) async {
    final navigator = Navigator.of(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        scrollable: false,
        title: Text(title ?? '共 ${distinct.length} 项'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '共 ${distinct.length} 项：',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              for (final value in distinct)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(value)),
                      if (onDetail != null &&
                          (detailAvailableOf?.call(value) ?? true))
                        UtenTableCellAction(
                          key: ValueKey('multi-value-detail-$value'),
                          label: detailLabel,
                          onPressed: () {
                            navigator.pop();
                            onDetail!(value);
                          },
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
