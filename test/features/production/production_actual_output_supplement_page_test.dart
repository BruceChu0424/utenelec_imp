import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/pages/production_actual_output_supplement_page.dart';
import 'package:uten_imp/features/production/repositories/production_material_increment_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets(
    'planner can cancel an unposted supplement with an explicit reason',
    (tester) async {
      final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
      String status = 'DRAFT';
      Map<String, dynamic>? submitted;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            if (request.path.endsWith('/cancel')) {
              submitted = Map<String, dynamic>.from(request.data as Map);
              status = 'CANCELLED';
            }
            handler.resolve(
              Response(
                requestOptions: request,
                statusCode: 200,
                data: {
                  'id': 'supplement',
                  'status': status,
                  'sourceSegmentId': 'original-task',
                  'actualQty': 130,
                  'originalReportQty': 100,
                  'supplementQty': 30,
                  'sourceLine': {
                    'planItemId': 'original-item',
                    'planNo': 'SJ-ORIGINAL',
                    'goodsId': 'goods',
                    'goodsName': '同一批自制件',
                    'maxReportQty': 100,
                  },
                },
              ),
            );
          },
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiClientProvider.overrideWithValue(ApiClient(dio)),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue({
              Perm.productionPlanApprove,
            }),
          ],
          child: const MaterialApp(
            home: ProductionActualOutputSupplementPage(id: 'supplement'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('取消追加计划'));
      await tester.tap(find.text('取消追加计划'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), '重复登记的实物批次');
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(submitted?['reason'], '重复登记的实物批次');
      expect(
        submitted?['idempotencyKey'],
        startsWith('actual-supplement-cancel-'),
      );
      expect(find.textContaining('追加申请已取消'), findsOneWidget);
      expect(find.text('取消追加计划'), findsNothing);
      expect(find.textContaining('同一批实际产出 130'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final (allowed, complete) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'supplement material entry uses target task: permission=$allowed complete=$complete',
      (tester) async {
        final dio = Dio(BaseOptions(baseUrl: 'http://localhost/api'));
        dio.interceptors.add(
          InterceptorsWrapper(
            onRequest: (request, handler) {
              handler.resolve(
                Response(
                  requestOptions: request,
                  statusCode: 200,
                  data: {
                    'id': 'supplement',
                    'status': 'APPROVED',
                    'planNo': 'SJ-SUPPLEMENT',
                    'sourceSegmentId': 'original-task',
                    'supplementSegmentId': 'supplement-task',
                    'supplementSegmentStatus': complete ? 'COMPLETED' : 'READY',
                    'actualQty': 130,
                    'originalReportQty': 100,
                    'supplementQty': 30,
                    'sourceLine': {
                      'planItemId': 'original-item',
                      'planNo': 'SJ-ORIGINAL',
                      'goodsId': 'goods',
                      'goodsName': '同一批自制件',
                      'maxReportQty': 100,
                    },
                  },
                ),
              );
            },
          ),
        );
        final router = GoRouter(
          initialLocation: '/supplement',
          routes: [
            GoRoute(
              path: '/supplement',
              builder: (_, _) =>
                  const ProductionActualOutputSupplementPage(id: 'supplement'),
            ),
            GoRoute(
              path: '/production/material-increment-requests/new',
              builder: (_, state) => Scaffold(
                body: Text('申请来源 ${state.uri.queryParameters['segmentId']}'),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              apiClientProvider.overrideWithValue(ApiClient(dio)),
              isSuperAdminProvider.overrideWithValue(false),
              currentPermissionsProvider.overrideWithValue({
                Perm.productionExecutionView,
                if (allowed) productionMaterialIncrementPermission,
              }),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('同一批实际产出 130'), findsOneWidget);
        expect(
          find.text('申请追加用料'),
          allowed && !complete ? findsOneWidget : findsNothing,
        );
        if (allowed && !complete) {
          await tester.ensureVisible(find.text('申请追加用料'));
          await tester.tap(find.text('申请追加用料'));
          await tester.pumpAndSettle();
          expect(find.text('申请来源 supplement-task'), findsOneWidget);
        }
        if (complete) expect(find.textContaining('已完成登记'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
