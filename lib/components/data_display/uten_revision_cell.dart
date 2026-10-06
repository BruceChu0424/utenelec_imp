// 单元格内旧新对照：上一行旧值红删除线、下一行新值绿底加粗，
// 新值里实际变化的字符位红色加粗下划线——证件号码这类逐位校对的字段差在哪一位一眼可见。
// 使用方：员工资料核对更正页(HrReconcilePage，ADR-160)在表格单元格内对照单字段旧/新值；
// 表头级字段对照仍用 UtenRevisionFields(带 −/+ 前缀容器)，整行快照对照用 UtenRevisionTable。
// 只负责显示，不读业务接口，不决定两个版本如何配对。
import 'package:flutter/material.dart';

import 'uten_revision_table.dart';

/// 表格单元格内的紧凑「旧值 → 新值」两行对照。
///
/// 旧值红色删除线(为空时灰字占位、不加线)；新值绿底 [FontWeight.w700]，
/// [changedPositions] 指定的 1-based 字符位红色 [FontWeight.w800] 加下划线。
/// [masked] 为 true 时不做差异位高亮——脱敏值的逐位对照没有意义。
/// [after] 为 null 表示没有新值(不渲染新值行)。颜色全部复用
/// [utenRevisionForeground]/[utenRevisionBackground]，明暗主题自动适配。
class UtenRevisionCell extends StatelessWidget {
  const UtenRevisionCell({
    super.key,
    required this.before,
    required this.after,
    this.changedPositions = const [],
    this.masked = false,
    this.emptyText,
    this.afterTrailing,
  });

  /// 修改前的值；null 或空串按「原本为空」显示占位文字。
  final String? before;

  /// 修改后的值；null 表示该字段没有新值，不渲染新值行。
  final String? after;

  /// 新值中实际变化的字符位(1-based)。
  final List<int> changedPositions;

  /// 脱敏值不做逐位差异高亮(整行新值统一绿字)。
  final bool masked;

  /// 旧值为空时显示的占位文字，默认「(空)」。
  final String? emptyText;

  /// 新值行尾部小部件(「采用」按钮/对勾等)。
  final Widget? afterTrailing;

  @override
  Widget build(BuildContext context) {
    final hasBefore = before != null && before!.isNotEmpty;
    final beforeLabel = hasBefore ? before! : (emptyText ?? '(空)');
    return Semantics(
      label: after == null ? '修改前 $beforeLabel' : '修改前 $beforeLabel，改为 $after',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            beforeLabel,
            style: hasBefore
                ? _removedStyle(context)
                : TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
          ),
          if (after != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: utenRevisionBackground(context, UtenRevisionKind.added),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text.rich(TextSpan(children: _afterSpans(context))),
                  ),
                  if (afterTrailing != null) ...[
                    const SizedBox(width: 4),
                    afterTrailing!,
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }

  TextStyle _removedStyle(BuildContext context) {
    final color = utenRevisionForeground(context, UtenRevisionKind.removed)!;
    return TextStyle(
      color: color,
      decoration: TextDecoration.lineThrough,
      decorationColor: color,
    );
  }

  List<InlineSpan> _afterSpans(BuildContext context) {
    final added = utenRevisionForeground(context, UtenRevisionKind.added)!;
    final changed = changedPositions.toSet();
    return [
      for (var i = 0; i < after!.length; i++)
        if (masked || !changed.contains(i + 1))
          TextSpan(
            text: after![i],
            style: TextStyle(color: added, fontWeight: FontWeight.w700),
          )
        else
          TextSpan(text: after![i], style: _changedStyle(context)),
    ];
  }

  TextStyle _changedStyle(BuildContext context) {
    final color = utenRevisionForeground(context, UtenRevisionKind.removed)!;
    return TextStyle(
      color: color,
      fontWeight: FontWeight.w800,
      decoration: TextDecoration.underline,
      decorationColor: color,
    );
  }
}
