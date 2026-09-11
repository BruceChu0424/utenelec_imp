// 产成品入库任务独立页（/warehouse/production-finished-in/tasks，深链保底）。
// 正文逻辑在 widgets/production_finished_inbound_tasks_view.dart；2026-09-01 起主
// 入口是「入库任务中心 · 产成品入库」待点收分段（/warehouse/tasks/inbound）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../widgets/production_finished_inbound_tasks_view.dart';

class ProductionFinishedInboundTasksPage extends ConsumerStatefulWidget {
  const ProductionFinishedInboundTasksPage({super.key});

  @override
  ConsumerState<ProductionFinishedInboundTasksPage> createState() =>
      _ProductionFinishedInboundTasksPageState();
}

class _ProductionFinishedInboundTasksPageState
    extends ConsumerState<ProductionFinishedInboundTasksPage> {
  String? _myLocation;
  int _refreshTick = 0;
  bool _viewLoading = false;

  /// onPageResume 首次触发是「进入本页」的导航结算，不是返回——跳过一次，
  /// 避免进入即重复拉取（首次加载已在视图 initState 完成）。
  bool _resumeArmed = false;

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(
      context,
      RouteName.warehouseProductionFinishedInboundTasks,
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
        title: '产成品入库任务',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          UtenAppBarActionButton(
            key: const Key('production-finished-inbound-refresh'),
            label: '刷新',
            icon: Icons.refresh_rounded,
            isLoading: _viewLoading && _refreshTick > 0,
            onPressed: _viewLoading
                ? null
                : () => setState(() => _refreshTick++),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: ProductionFinishedInboundTasksView(
              refreshTick: _refreshTick,
              onLoadingChanged: (loading) {
                if (mounted) setState(() => _viewLoading = loading);
              },
            ),
          ),
        ),
      ),
    );
  }
}
