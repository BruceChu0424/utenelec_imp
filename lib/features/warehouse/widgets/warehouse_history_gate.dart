// 仓库历史单据时间门控容器：任务中心各小类行末尾「历史单据」段的标准载体。
//
// 2026-09-03 统一范式：仓库出库/入库任务中心各分段小类行末尾的「历史单据」段
// 被选中后，内容区渲染本组件——时间行（UtenHistoryTimeFilter：时间段/全部）；
// 2026-10-04 起默认值改为「全部」（用户口径：进历史段直接看全量列表），
// 按 [UtenHistoryTimeValue.all] 构建列表子树（builder 收到当前时间值，
// 自行转 dateFrom/dateTo 查询）；「时间段/全部」胶囊仍可随时切换。
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

  /// 宿主（任务中心大类行/小类行）：钉在时间行上方常驻——未选时间段时也
  /// 可见可切（2026-10-01 修「点历史类分类后分类栏消失」），不随列表滚走。
  final Widget? externalHeader;

  /// 列表子树构建器；仅在时间值非 none 时被调用。
  final Widget Function(UtenHistoryTimeValue value) builder;

  @override
  State<WarehouseHistoryGate> createState() => _WarehouseHistoryGateState();
}

class _WarehouseHistoryGateState extends State<WarehouseHistoryGate> {
  UtenHistoryTimeValue _time = const UtenHistoryTimeValue.all();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.externalHeader != null) ...[
          widget.externalHeader!,
          const SizedBox(height: UtenSpacing.s12),
        ],
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
