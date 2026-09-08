import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_doc.dart';
import 'package:uten_imp/features/subcontract/models/subcontract_order_progress.dart';
import 'package:uten_imp/features/subcontract/repositories/subcontract_repository.dart';
import 'package:uten_imp/features/subcontract/widgets/subcontract_order_progress.dart';

class _ProgressRepository extends SubcontractRepository {
  _ProgressRepository({required this.canOpen})
    : super(ApiClient(Dio()), SubcontractDocType.order);

  final bool canOpen;
  bool ready = false;

  @override
  Future<SubcontractOrderProgress> orderProgress(String id) async =>
      SubcontractOrderProgress.fromJson({
        'orderId': id,
        'status': 0,
        'materialRequired': true,
        'materialLines': [
          {
            'planItemId': 'actual-order-item',
            'goodsName': '待喷涂外壳',
            'unitName': '个',
            'flowMode': 'DRAFT_PREPARATION',
            'preparationStatus': ready ? 'READY_FOR_FINANCE' : 'WAITING_PLAN',
            'plannedQty': 5,
            'preparedQty': ready ? 5 : 2,
            'remainingQty': ready ? 0 : 3,
            'readyOutboundQty': 0,
            'preparationAnalysisId': 'analysis-1',
            'allowedActions': [if (canOpen) 'OPEN_ANALYSIS'],
          },
        ],
      });
}

void main() {
  for (final canOpen in [true, false]) {
    testWidgets('草稿先内部生产再财审，关联入口按服务端允许动作显示 $canOpen', (tester) async {
      tester.view.physicalSize = const Size(1600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _ProgressRepository(canOpen: canOpen);
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(
              body: SingleChildScrollView(
                child: SubcontractOrderProgressSection(orderId: 'order-1'),
              ),
            ),
          ),
          GoRoute(
            path: '/production/material-analyses/:id/summary',
            builder: (_, state) =>
                Scaffold(body: Text('生产安排:${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            subcontractRepositoryProvider(
              SubcontractDocType.order,
            ).overrideWithValue(repository),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('等待计划安排'), findsOneWidget);
      expect(find.text('已备齐 2 个'), findsOneWidget);
      expect(find.text('还需生产 3 个'), findsOneWidget);
      expect(find.textContaining('当前可出'), findsNothing);
      expect(
        tester.getTopLeft(find.text('内部生产')).dx,
        lessThan(tester.getTopLeft(find.text('财务审批')).dx),
      );
      expect(find.text('查看生产安排'), canOpen ? findsOneWidget : findsNothing);
      repository.ready = true;
      await tester.tap(find.byTooltip('刷新进度'));
      await tester.pumpAndSettle();
      expect(find.text('已备齐，可提交财务'), findsOneWidget);
      expect(find.text('还需生产 0 个'), findsOneWidget);
      if (canOpen) {
        await tester.tap(find.text('查看生产安排'));
        await tester.pumpAndSettle();
        expect(find.text('生产安排:analysis-1'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }
}
