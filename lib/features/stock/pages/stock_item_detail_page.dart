// 库存详情页 (/stock/item/:goodsId?tab=balance|ledger|weight) —— 即时库存双击货品行进入。
//
// 本页只是单货品库存面板 (lib/shared/stock_ledger/goods_stock_ledger_panel.dart) 的宿主:
// 标题 (货品名 · 编号 · 系列 · 库位) + 刷新 + 返回即刷新; 余额 / 出入库流水 / 单重学习
// 三个分段与货品详情「库存与出入库」页签完全同一套。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/stock_query.dart';
import '../models/instant_inventory_scope.dart';
import '../../../shared/stock_ledger/goods_stock_ledger_panel.dart';
import '../../../shared/stock_ledger/stock_ledger_models.dart';

class StockItemDetailPage extends ConsumerStatefulWidget {
  const StockItemDetailPage({
    super.key,
    required this.goodsId,
    this.initialTab,
    this.initialScope = const InstantInventoryScope.full(),
    this.returnTo,
  });

  final String goodsId;

  /// 路由 ?tab=: balance (库存余额, 默认) / ledger (出入库流水) / weight (单重学习)。
  final String? initialTab;
  final InstantInventoryScope initialScope;
  final String? returnTo;

  @override
  ConsumerState<StockItemDetailPage> createState() =>
      _StockItemDetailPageState();
}

class _StockItemDetailPageState extends ConsumerState<StockItemDetailPage> {
  final _panelKey = GlobalKey<GoodsStockLedgerPanelState>();
  String? _myLocation;
  InstantInventoryRow? _goods;

  void _syncLocation({
    InstantInventoryScope? scope,
    GoodsStockLedgerSegment? segment,
  }) {
    final panel = _panelKey.currentState;
    final path = RouteName.stockItemDetail(
      widget.goodsId,
      tab:
          (segment ??
                  panel?.segment ??
                  GoodsStockLedgerSegment.parse(widget.initialTab))
              .key,
      scope: scope ?? panel?.scope ?? widget.initialScope,
      returnTo: widget.returnTo,
    );
    _myLocation = Uri.parse(path).path;
    context.replace(path);
  }

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(
      context,
      RouteName.stockItemDetail(widget.goodsId),
    );
    // 返回即刷新: 从源单据做过红冲/出库等写操作回来, 余额与流水静默重取。
    ref.onPageResume(_myLocation!, () => _panelKey.currentState?.reload());
    final goods = _goods;
    final goodsLabel = [
      goods?.name ?? widget.goodsId,
      if (goods?.goodsCode?.isNotEmpty == true) goods!.goodsCode,
      if (goods?.series?.isNotEmpty == true) '系列 ${goods!.series}',
      if (goods?.stockPlace?.isNotEmpty == true) '库位 ${goods!.stockPlace}',
    ].join(' · ');
    return Scaffold(
      appBar: UtenAppBar(
        title: '库存详情',
        subtitle: goodsLabel,
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.stockInstantInventory,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () => _panelKey.currentState?.reload(),
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: UtenSpacing.s16,
              horizontal: UtenSpacing.s4,
            ),
            child: GoodsStockLedgerPanel(
              key: _panelKey,
              goodsId: widget.goodsId,
              initialSegment: GoodsStockLedgerSegment.parse(widget.initialTab),
              initialScope: widget.initialScope,
              onScopeChanged: (scope) => _syncLocation(scope: scope),
              onSegmentChanged: (segment) => _syncLocation(segment: segment),
              onGoodsLoaded: (goods) {
                if (mounted) setState(() => _goods = goods);
              },
            ),
          ),
        ),
      ),
    );
  }
}
