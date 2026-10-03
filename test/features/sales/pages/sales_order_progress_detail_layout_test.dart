// 订单进度详情页版式统一（2026-09-12）：摘要卡放大、履约进度折叠卡上移
// （默认折叠只露最新状态胶囊）、产品进度沉底、刷新进 AppBar 右上、业务动作
// （修改订单/去发货(N)）收敛右下悬浮组、产品表行单击只选中不弹窗。本文件锁定。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/pages/sales_order_progress_detail_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'page layout: collapsed timeline above product progress, refresh in app bar, floating actions',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(_LayoutApi()),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesOrderView,
              Perm.salesOrderEdit,
              Perm.salesShipmentView,
              Perm.salesShipmentCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: SalesOrderProgressDetailPage(orderId: 'order-1'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 刷新收进 AppBar 右上（整页口径）。
      expect(find.text('刷新'), findsOneWidget);

      // 摘要卡字段（放大后仍在）。
      expect(find.text('SO-1'), findsOneWidget);
      expect(find.textContaining('开单日期'), findsOneWidget);

      // 履约进度默认折叠：常驻最新状态胶囊，历史节点不可见
      // （AnimatedCrossFade 折叠子树仍在 element 树中，但被裁剪不可点）。
      expect(find.text('履约进度'), findsOneWidget);
      expect(find.textContaining('最新：财务审核通过'), findsOneWidget);
      expect(find.text('销售下单').hitTestable(), findsNothing);

      // 顺序：摘要 → 履约进度 → 产品进度（沉底）。
      final summaryTop = tester.getTopLeft(find.text('SO-1')).dy;
      final timelineTop = tester.getTopLeft(find.text('履约进度')).dy;
      final productTop = tester.getTopLeft(find.text('产品进度')).dy;
      expect(summaryTop, lessThan(timelineTop));
      expect(timelineTop, lessThan(productTop));

      // 右下悬浮组：已选胶囊 + 去发货（红） + 修改订单。
      expect(find.byType(UtenSelectionSummaryPill), findsOneWidget);
      expect(find.text('去发货'), findsOneWidget);
      expect(find.text('修改订单'), findsOneWidget);

      // 展开履约进度后历史节点可见。
      await tester.tap(find.text('履约进度'));
      await tester.pumpAndSettle();
      expect(find.text('销售下单').hitTestable(), findsOneWidget);

      // 新口径：未开始的阶段整块在最上（最后的阶段在最顶）、进度开始（销售下单）垫底。
      final productionTop = tester.getTopLeft(find.text('生产开工')).dy;
      final supplyTop = tester.getTopLeft(find.text('物料准备-采购/委外下单')).dy;
      final latestTop = tester.getTopLeft(find.text('财务审核通过')).dy;
      final startTop = tester.getTopLeft(find.text('销售下单')).dy;
      expect(productionTop, lessThan(supplyTop));
      expect(supplyTop, lessThan(latestTop));
      expect(latestTop, lessThan(startTop));

      // 「最新」徽章仍落在第一条已发生事件（财务审核通过）上，不被 PENDING 抢走。
      expect(find.text('最新'), findsOneWidget);
      expect(tester.getTopLeft(find.text('最新')).dy, greaterThan(supplyTop));

      // 产品表行单击只选中（去发货计数联动），不弹进度弹窗。
      await tester.tap(find.text('产品甲'));
      await tester.pumpAndSettle();
      expect(find.text('去发货(1)'), findsOneWidget);
      expect(find.textContaining(' · 进度来源'), findsNothing);

      expect(tester.takeException(), isNull);
    },
  );
}

class _LayoutApi extends ApiClient {
  _LayoutApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/sales/orders/order-1') {
      return {
        'id': 'order-1',
        'billNo': 'SO-1',
        'billDate': '2026-09-01',
        'deliverDate': '2026-09-30',
        'makerName': '李销售',
        'status': 1,
        'writable': true,
        'financeConfirmed': true,
        'financeRejected': false,
        'stopped': false,
        'closed': false,
        'items': const <Map<String, dynamic>>[],
      };
    }
    return const <String, dynamic>{};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path.contains('progress-timeline')) {
      // 服务端口径（2026-10-01）：未开始的 PENDING 整块置顶（最后的阶段在最顶），
      // 其下已发生事件按时间倒序、下单垫底。
      return const [
        {
          'seq': 70,
          'code': 'PRODUCTION_PROGRESS',
          'title': '生产开工',
          'state': 'PENDING',
          'detail': '已产 0 / 订货 10',
        },
        {
          'seq': 50,
          'code': 'SUPPLY_ORDER',
          'title': '物料准备-采购/委外下单',
          'state': 'PENDING',
          'detail': '物料分析缺口待采购/委外在任务中心下单',
        },
        {
          'seq': 3,
          'code': 'FINANCE_CONFIRMED',
          'title': '财务审核通过',
          'state': 'DONE',
          'occurredAt': '2026-09-10T02:30:00Z',
        },
        {
          'seq': 1,
          'code': 'ORDER_CREATED',
          'title': '销售下单',
          'state': 'DONE',
          'occurredAt': '2026-09-09T02:00:00Z',
        },
      ];
    }
    if (path.contains('plan-progress')) {
      return const [
        {
          'orderItemId': 'order-item-1',
          'goodsName': '产品甲',
          'qty': 10,
          'plannedQty': 10,
          'producedQty': 4,
          'shippedQty': 2,
          'shippableQty': 2,
          'pendingShipmentQty': 0,
          'links': <Map<String, dynamic>>[],
        },
      ];
    }
    return const <Map<String, dynamic>>[];
  }
}
