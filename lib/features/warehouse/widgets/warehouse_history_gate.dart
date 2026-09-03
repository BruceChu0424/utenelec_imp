// 仓库历史单据时间门控容器：任务中心各小类行末尾「历史单据」段的标准载体。
//
// 2026-09-03 统一范式：仓库出库/入库任务中心各分段小类行末尾的「历史单据」段
// 被选中后，内容区渲染本组件——时间行（UtenHistoryTimeFilter：时间段/全部，
// 默认不选）+ 引导占位（未选时间不发请求）；选定时间段或「全部」后才按值
// 构建列表子树（builder 收到当前时间值，自行转 dateFrom/dateTo 查询）。
import 'package:flutter/material.dart';

import '../../../components/layout/uten_history_time_filter.dart';
import '../../../core/theme/uten_tokens.dart';

class WarehouseHistoryGate extends StatefulWidget {
  const WarehouseHistoryGate({super.key, this.timeKey, required this.builder});

  /// 时间行 key（页面测试锚点透传）。
  final Key? timeKey;

  /// 列表子树构建器；仅在时间值非 none 时被调用。
  final Widget Function(UtenHistoryTimeValue value) builder;

  @override
  State<WarehouseHistoryGate> createState() => _WarehouseHistoryGateState();
}

class _WarehouseHistoryGateState extends State<WarehouseHistoryGate> {
  UtenHistoryTimeValue _time = const UtenHistoryTimeValue.none();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            bottom: UtenSpacing.s8,
            left: UtenSpacing.s4,
            right: UtenSpacing.s4,
          ),
          child: UtenHistoryTimeFilter(
            key: widget.timeKey,
            value: _time,
            onChanged: (value) => setState(() => _time = value),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: _time.isNone
              ? const UtenHistoryTimePlaceholder()
              : widget.builder(_time),
        ),
      ],
    );
  }
}
