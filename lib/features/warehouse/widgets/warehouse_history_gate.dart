// Shared warehouse history gate. The owner supplies a category header; the
// builder receives the current date contract and its toolbar action. History
// defaults to the recent month, and none still prevents mounting the reader.
import 'package:flutter/material.dart';

import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/theme/uten_tokens.dart';

class WarehouseHistoryGate extends StatefulWidget {
  const WarehouseHistoryGate({
    super.key,
    this.timeKey,
    this.externalHeader,
    required this.builder,
  });

  /// 时间行 key（页面测试锚点透传）。
  final Key? timeKey;

  /// 宿主任务分类保持常驻；日期入口由 builder 放进实际历史表工具栏。
  final Widget? externalHeader;

  /// 仅在时间值非 none 时构建读取子树，并显式传入同一日期工具栏入口。
  final Widget Function(UtenHistoryTimeValue value, Widget timeAction) builder;

  @override
  State<WarehouseHistoryGate> createState() => _WarehouseHistoryGateState();
}

class _WarehouseHistoryGateState extends State<WarehouseHistoryGate> {
  UtenHistoryTimeValue _time = UtenHistoryTimeValue.lastMonth();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.externalHeader != null) ...[
          widget.externalHeader!,
          const SizedBox(height: UtenFilterRow.rowGap),
        ],
        Expanded(
          child: _time.isNone
              ? UtenHistoryTimePlaceholder(
                  controls: UtenHistoryTimeFilter(
                    key: widget.timeKey,
                    value: _time,
                    onChanged: (value) => setState(() => _time = value),
                  ),
                )
              : widget.builder(
                  _time,
                  UtenHistoryTimeFilter(
                    key: widget.timeKey,
                    value: _time,
                    onChanged: (value) => setState(() => _time = value),
                  ),
                ),
        ),
      ],
    );
  }
}
