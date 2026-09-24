import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/data_display/uten_revision_table.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/production/models/production_execution_workbench.dart';
import 'package:uten_imp/features/production/repositories/production_overproduction_rate_repository.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_request_dialog.dart';
import 'package:uten_imp/features/production/widgets/production_overproduction_rate_revision.dart';

ProductionOverproductionRateRequest _request() =>
    ProductionOverproductionRateRequest({
      'id': 'request',
      'segmentId': 'segment',
      'status': 'PENDING',
      'rowVersion': 0,
      'beforeRate': 0.1,
      'requestedRate': 0.15,
      'beforeSnapshot': {
        'items': [
          {
            'itemId': 'segment',
            'goodsName': '测试自制件',
            'plannedQty': 100,
            'allowedOverproductionRate': 0.1,
            'allowedTotalQty': 110,
          },
        ],
      },
      'afterSnapshot': {
        'items': [
          {
            'itemId': 'segment',
            'goodsName': '测试自制件',
            'plannedQty': 100,
            'allowedOverproductionRate': 0.15,
            'allowedTotalQty': 115,
          },
        ],
      },
    });

void main() {
  test(
    'pending request keeps effective rate and uses immutable old/new rows',
    () {
      final task = ProductionExecutionWorkbenchSegment.fromJson({
        'allowedOverproductionRate': 0.1,
        'pendingOverproductionRate': 0.15,
        'pendingOverproductionRateRequestId': 'request',
      });
      expect(task.allowedOverproductionRate, 0.1);
      expect(task.pendingOverproductionRate, 0.15);
      final rows = productionRateRevisionRows(_request())!;
      expect(rows.map((row) => row.kind), [
        UtenRevisionKind.removed,
        UtenRevisionKind.added,
      ]);
      expect(rows.first.value['allowedOverproductionRate'], 0.1);
      expect(rows.last.value['allowedOverproductionRate'], 0.15);
      final broken = _request();
      broken.data['beforeSnapshot'] = {
        'items': [
          {'itemId': 'another-task'},
        ],
      };
      expect(productionRateRevisionRows(broken), isNull);
    },
  );

  testWidgets('approval reuses red strike and green added revision rows', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProductionOverproductionRateRevision(request: _request()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(UtenRevisionStrike), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('15%'), findsOneWidget);
    expect(find.text('− 申请前'), findsOneWidget);
    expect(find.text('+ 申请后'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed request preserves typed values and never applies pending rate',
    (tester) async {
      final source = ProductionOverproductionRateContext({
        'segmentId': 'segment',
        'segmentCode': 'ZX-1',
        'effectiveRate': 0.1,
        'rateVersion': 7,
        'canSubmit': true,
      });
      final repository = _FailingRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            productionOverproductionRateRepositoryProvider.overrideWithValue(
              repository,
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () =>
                      showProductionRateRequestDialog(context, source),
                  child: const Text('申请'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('申请'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), '15');
      await tester.enterText(find.byType(TextField).at(1), '本批工艺需要');
      await tester.tap(find.text('提交申请'));
      await tester.pumpAndSettle();
      expect(repository.rate, 0.15);
      expect(repository.version, 7);
      expect(source.effectiveRate, 0.1);
      expect(find.text('15'), findsOneWidget);
      expect(find.text('比例版本已变化，请刷新'), findsOneWidget);
      expect(find.textContaining('当前有效 10%'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final pending in [false, true]) {
    testWidgets(
      'conflict refresh retains input and uses latest context: pending=$pending',
      (tester) async {
        final repository = _RefreshingRepository(pending: pending);
        final source = ProductionOverproductionRateContext({
          'segmentId': 'segment',
          'segmentCode': 'ZX-1',
          'effectiveRate': 0.1,
          'rateVersion': 7,
          'requestGeneration': 2,
          'canSubmit': true,
        });
        ProductionOverproductionRateRequest? submitted;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () async => submitted =
                      await showProductionRateRequestDialog(context, source),
                  child: const Text('申请'),
                ),
              ),
            ),
            GoRoute(
              path: '/production/overproduction-rate-requests/:id',
              builder: (_, state) =>
                  Scaffold(body: Text('原申请 ${state.pathParameters['id']}')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              productionOverproductionRateRepositoryProvider.overrideWithValue(
                repository,
              ),
            ],
            child: MaterialApp.router(routerConfig: router),
          ),
        );
        await tester.tap(find.text('申请'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).at(0), '15');
        await tester.enterText(find.byType(TextField).at(1), '本批工艺需要');
        await tester.tap(find.text('提交申请'));
        await tester.pumpAndSettle();
        expect(repository.contexts.map((context) => context.rateVersion), [7]);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('重新核对当前比例'));
        await tester.pumpAndSettle();
        expect(find.text('15'), findsOneWidget);
        expect(find.text('本批工艺需要'), findsOneWidget);
        expect(find.textContaining('当前有效 12%'), findsOneWidget);
        expect(
          source.effectiveRate,
          0.1,
          reason: 'Read refresh must not mutate original caller snapshot',
        );
        if (pending) {
          expect(
            tester
                .widget<FilledButton>(find.widgetWithText(FilledButton, '提交申请'))
                .onPressed,
            isNull,
          );
          await tester.tap(find.text('已有 14% 待审批 · 查看原申请'));
          await tester.pumpAndSettle();
          expect(find.text('原申请 existing'), findsOneWidget);
          expect(find.byType(AlertDialog), findsNothing);
          expect(submitted, isNull);
          expect(repository.contexts, hasLength(1));
        } else {
          await tester.tap(find.text('提交申请'));
          await tester.pumpAndSettle();
          expect(repository.contexts.map((context) => context.rateVersion), [
            7,
            8,
          ]);
          expect(repository.contexts.last.requestGeneration, 3);
          expect(repository.rate, 0.15);
          expect(repository.reason, '本批工艺需要');
          expect(submitted?.beforeRate, 0.12);
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}

class _FailingRepository extends ProductionOverproductionRateRepository {
  _FailingRepository() : super(ApiClient(Dio()));
  double? rate;
  int? version;
  @override
  Future<ProductionOverproductionRateRequest> submit(
    ProductionOverproductionRateContext context,
    double rate,
    String reason,
  ) async {
    this.rate = rate;
    version = context.rateVersion;
    throw ApiException('CONFLICT', '比例版本已变化，请刷新');
  }
}

class _RefreshingRepository extends ProductionOverproductionRateRepository {
  _RefreshingRepository({required this.pending}) : super(ApiClient(Dio()));
  final bool pending;
  final contexts = <ProductionOverproductionRateContext>[];
  double? rate;
  String? reason;
  @override
  Future<ProductionOverproductionRateContext> context(String segmentId) async =>
      ProductionOverproductionRateContext({
        'segmentId': segmentId,
        'segmentCode': 'ZX-1',
        'effectiveRate': 0.12,
        'rateVersion': 8,
        'requestGeneration': 3,
        'canSubmit': !pending,
        if (pending) 'pendingRequestId': 'existing',
        if (pending) 'pendingRate': 0.14,
      });
  @override
  Future<ProductionOverproductionRateRequest> submit(
    ProductionOverproductionRateContext context,
    double rate,
    String reason,
  ) async {
    contexts.add(context);
    this.rate = rate;
    this.reason = reason;
    if (context.rateVersion == 7) throw ApiException('CONFLICT', '比例版本已变化，请刷新');
    return ProductionOverproductionRateRequest({
      ..._request().data,
      'beforeRate': 0.12,
    });
  }
}
