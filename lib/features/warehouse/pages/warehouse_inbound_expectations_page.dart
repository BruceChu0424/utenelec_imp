// 预计到货任务中心独立页（/warehouse/inbound/expectations，深链保底；委外模块
// 卡片直达）。正文逻辑在 widgets/warehouse_inbound_expectations_view.dart；
// 2026-09-01 起主入口是「入库任务中心」的采购入库/委外入库分段
//（/warehouse/tasks/inbound）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../widgets/warehouse_inbound_expectations_view.dart';

class WarehouseInboundExpectationsPage extends ConsumerStatefulWidget {
  const WarehouseInboundExpectationsPage({super.key});

  @override
  ConsumerState<WarehouseInboundExpectationsPage> createState() =>
      _WarehouseInboundExpectationsPageState();
}

class _WarehouseInboundExpectationsPageState
    extends ConsumerState<WarehouseInboundExpectationsPage> {
  String? _myLocation;
  int _refreshTick = 0;

  /// onPageResume 首次触发是「进入本页」的导航结算，不是返回——跳过一次，
  /// 避免进入即重复拉取（首次加载已在视图 initState 完成）。
  bool _resumeArmed = false;

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(
      context,
      RouteName.warehouseInboundExpectations,
    );
    ref.onPageResume(_myLocation!, () {
      if (!_resumeArmed) {
        _resumeArmed = true;
        return;
      }
      setState(() => _refreshTick++);
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: '预计到货任务中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
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
            child: WarehouseInboundExpectationsView(refreshTick: _refreshTick),
          ),
        ),
      ),
    );
  }
}
