// 产品进度面板统一悬浮模式（2026-09-12 版式统一；2026-09-13 修订）：
// 宿主传入 SalesShipmentActionScope 后，面板不再渲染「全选可发产品/去发货/
// 刷新产品进度」工具条与说明文字；表格只展示「本次可发」（不再提供「本次发货
// 数量」输入列——数量在出货单明细里填写）；行单击只切换勾选不弹窗（弹窗只由
// 「查看进度」触发）；右下悬浮按钮经 scope.createShipment 按可发量预填跳转。
// 本文件锁定以上契约。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/features/sales/widgets/sales_plan_progress_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'unified mode hides legacy toolbar, shows available only, and ships available quantities',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _ShippableRepository();
      final scope = SalesShipmentActionScope();
      addTearDown(scope.dispose);
      var openedCount = 0;
      Uri? opened;
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(
                child: SalesPlanProgressPanel(
                  orderId: 'order-1',
                  canShip: true,
                  shipmentActions: scope,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/sales/shipments/new',
            builder: (context, state) {
              openedCount++;
              opened = state.uri;
              return Scaffold(
                body: TextButton(
                  onPressed: context.pop,
                  child: const Text('返回产品进度'),
                ),
              );
            },
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            salesRepositoryProvider(
              SalesDocType.order,
            ).overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesShipmentView,
              Perm.salesShipmentCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 统一模式：面板内工具条与说明文字全部下线（去发货在宿主悬浮组）。
      expect(find.textContaining('全选可发产品'), findsNothing);
      expect(find.text('刷新产品进度'), findsNothing);
      expect(find.textContaining('已产按合格入库计算'), findsNothing);

      // 2026-09-13：不再提供「本次发货数量」输入列，只展示「本次可发」。
      expect(find.text('本次可发'), findsOneWidget);
      expect(find.text('本次发货数量'), findsNothing);
      expect(find.byType(TextField), findsNothing);

      // 悬浮桥就绪：可发货、尚未勾选。
      expect(scope.shippingEnabled, isTrue);
      expect(scope.selectedCount, 0);

      // 行单击只切换勾选，不弹进度弹窗。
      await tester.tap(find.text('产品甲'));
      await tester.pumpAndSettle();
      expect(scope.selectedCount, 1);
      expect(find.text('产品甲 · 进度来源'), findsNothing);

      // 「查看进度」列按钮才弹窗。
      await tester.tap(find.text('查看进度').first);
      await tester.pumpAndSettle();
      expect(find.text('产品甲 · 进度来源'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      // 勾选第二行批量发货：数量=各自本次可发（出货单里再调整）。
      await tester.tap(find.text('产品丙'));
      await tester.pumpAndSettle();
      expect(scope.selectedCount, 2);

      final shipping = scope.createShipment();
      await tester.pumpAndSettle();
      expect(openedCount, 1);
      expect(opened?.queryParameters, {
        'sourceOrderId': 'order-1',
        'orderItems': 'order-item-1:1.25,order-item-3:5',
      });
      await tester.tap(find.text('返回产品进度'));
      await shipping;
      await tester.pumpAndSettle();
      // 返回后进度重读、旧勾选清空。
      expect(repository.reads, 2);
      expect(scope.selectedCount, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'zero-available rows cannot be selected and shipping them is blocked',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1500, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final scope = SalesShipmentActionScope();
      addTearDown(scope.dispose);
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(
              body: SingleChildScrollView(
                child: SalesPlanProgressPanel(
                  orderId: 'order-1',
                  canShip: true,
                  shipmentActions: scope,
                ),
              ),
            ),
          ),
          GoRoute(
            path: '/sales/shipments/new',
            builder: (context, state) => Scaffold(
              body: TextButton(
                onPressed: context.pop,
                child: const Text('返回产品进度'),
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            salesRepositoryProvider(
              SalesDocType.order,
            ).overrideWithValue(_ShippableRepository()),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.salesShipmentView,
              Perm.salesShipmentCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();

      // 可发为 0 的行：idOf 返回 null，行单击不进入勾选集。
      await tester.tap(find.text('产品乙'));
      await tester.pumpAndSettle();
      expect(scope.selectedCount, 0);

      // 未勾选任何可发行时发起：不跳转、不报错。
      expect(await scope.createShipment(), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('返回产品进度'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _ShippableRepository extends SalesRepository {
  _ShippableRepository() : super(ApiClient(Dio()), SalesDocType.order);
  int reads = 0;

  @override
  Future<List<OrderPlanProgressLine>> planProgress(String id) async {
    reads++;
    return const [
      OrderPlanProgressLine(
        orderItemId: 'order-item-1',
        goodsName: '产品甲',
        qty: 1000,
        plannedQty: 1000,
        producedQty: 10,
        shippedQty: 0,
        shippableQty: 1.25,
        pendingShipmentQty: 8.75,
      ),
      OrderPlanProgressLine(
        orderItemId: 'order-item-2',
        goodsName: '产品乙',
        qty: 1000,
        plannedQty: 1000,
        producedQty: 0,
        shippedQty: 0,
        shippableQty: 0,
        pendingShipmentQty: 0,
      ),
      OrderPlanProgressLine(
        orderItemId: 'order-item-3',
        goodsName: '产品丙',
        qty: 6,
        plannedQty: 6,
        producedQty: 6,
        shippedQty: 1,
        shippableQty: 5,
        pendingShipmentQty: 0,
      ),
    ];
  }
}
