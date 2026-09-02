// 仓库实物单据历史独立列表页（/warehouse/history/:type，深链保底）。
// 正文逻辑在 widgets/warehouse_document_history_view.dart；2026-09-01 起采购/委外
// 收货与出仓历史以嵌入视图进入任务中心分段，本页保留独立路由与详情深链。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../config/warehouse_document_history_config.dart';
import '../widgets/warehouse_document_history_view.dart';

/// Warehouse-owned read-only history list.
class WarehouseDocumentHistoryListPage extends ConsumerStatefulWidget {
  const WarehouseDocumentHistoryListPage({super.key, required this.type});

  final WarehouseDocumentHistoryType type;

  @override
  ConsumerState<WarehouseDocumentHistoryListPage> createState() =>
      _WarehouseDocumentHistoryListPageState();
}

class _WarehouseDocumentHistoryListPageState
    extends ConsumerState<WarehouseDocumentHistoryListPage> {
  String? _myLocation;
  int _refreshTick = 0;

  /// onPageResume 首次触发是「进入本页」的导航结算，不是返回——跳过一次，
  /// 避免进入即重复拉取（首次加载已在视图 initState 完成）。
  bool _resumeArmed = false;

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(context, widget.type.listPath());
    ref.onPageResume(_myLocation!, () {
      if (!_resumeArmed) {
        _resumeArmed = true;
        return;
      }
      setState(() => _refreshTick++);
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.type.title,
        subtitle: '仓库实物视图',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: '/warehouse'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: Key('warehouse-history-refresh-${widget.type.segment}'),
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
            child: WarehouseDocumentHistoryView(
              type: widget.type,
              refreshTick: _refreshTick,
            ),
          ),
        ),
      ),
    );
  }
}
