// 仓库销售出库独立页（深链保底）：正文逻辑在
// widgets/warehouse_sales_outbound_workbench.dart，2026-09-01 起主入口是
// 「出库任务中心 · 销售出库」分段（/warehouse/tasks/outbound）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../providers/warehouse_sales_outbound_count_provider.dart';
import '../widgets/warehouse_sales_outbound_workbench.dart';

/// Dedicated warehouse projection for released sales outbound work.
class WarehouseSalesOutboundPage extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundPage({super.key});

  @override
  ConsumerState<WarehouseSalesOutboundPage> createState() =>
      _WarehouseSalesOutboundPageState();
}

class _WarehouseSalesOutboundPageState
    extends ConsumerState<WarehouseSalesOutboundPage> {
  String? _myLocation;
  int _refreshTick = 0;

  /// onPageResume 首次触发是「进入本页」的导航结算，不是返回——跳过一次，
  /// 避免进入即重复拉取（首次加载已在视图 initState 完成）。
  bool _resumeArmed = false;

  @override
  Widget build(BuildContext context) {
    // 返回即刷新：从详情页回到本页时重拉列表并同步角标。
    _myLocation ??= currentLocationOr(
      context,
      RouteName.warehouseSalesOutbound,
    );
    ref.onPageResume(_myLocation!, () {
      if (!_resumeArmed) {
        _resumeArmed = true;
        return;
      }
      setState(() => _refreshTick++);
      ref.invalidate(warehouseSalesOutboundPendingCountProvider);
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '仓库销售出库',
        subtitle: '拣货、异常恢复与交接',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/warehouse'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-sales-outbound-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              onPressed: () => setState(() => _refreshTick++),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: WarehouseSalesOutboundWorkbench(refreshTick: _refreshTick),
          ),
        ),
      ),
    );
  }
}
