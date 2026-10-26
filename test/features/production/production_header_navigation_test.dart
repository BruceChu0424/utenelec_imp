import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/router/page_resume_provider.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/production/models/production_material_analysis.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_history_page.dart';
import 'package:uten_imp/features/production/pages/production_material_analysis_page.dart';
import 'package:uten_imp/features/production/pages/production_plan_list_page.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

enum _Source { plans, analysis, history }

void main() {
  final cases = [
    (
      source: _Source.plans,
      label: '超产比例审批',
      destination: RouteName.productionOverproductionRateRequests,
      width: 1600.0,
    ),
    (
      source: _Source.plans,
      label: '超限产出处置',
      destination: RouteName.productionOverLimitDispositions,
      width: 1600.0,
    ),
    (
      source: _Source.analysis,
      label: '物料分析记录',
      destination: RouteName.productionMaterialAnalysisHistory,
      width: 1600.0,
    ),
    (
      source: _Source.analysis,
      label: '生产计划历史',
      destination: RouteName.productionPlanList,
      width: 1600.0,
    ),
    (
      source: _Source.analysis,
      label: '备料汇总预览',
      destination: RoutePath.productionMaterialAnalysisSummary('analysis-1'),
      width: 1600.0,
    ),
    (
      source: _Source.history,
      label: '生产计划历史',
      destination: RouteName.productionPlanList,
      width: 1600.0,
    ),
    (
      source: _Source.history,
      label: '生产计划历史',
      destination: RouteName.productionPlanList,
      width: 375.0,
    ),
  ];
  for (final scenario in cases) {
    testWidgets(
      '${scenario.source.name} header ${scenario.label} reopens after replace ${scenario.width}',
      (tester) async {
        await tester.binding.setSurfaceSize(Size(scenario.width, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        final requests = <RequestOptions>[];
        final api = _api(requests);
        final sourcePath = switch (scenario.source) {
          _Source.plans => RouteName.productionPlanList,
          _Source.analysis => RouteName.productionMaterialAnalysis,
          _Source.history => RouteName.productionMaterialAnalysisHistory,
        };
        final sourceWidget = switch (scenario.source) {
          _Source.plans => const ProductionPlanListPage(),
          _Source.analysis => const ProductionMaterialAnalysisPage(
            seed: ProductionMaterialAnalysisSeed(
              analysisId: 'analysis-1',
              warehouseId: 'warehouse-1',
            ),
          ),
          _Source.history => const ProductionMaterialAnalysisHistoryPage(),
        };
        final router = GoRouter(
          initialLocation: sourcePath,
          routes: [
            GoRoute(path: sourcePath, builder: (_, _) => sourceWidget),
            GoRoute(
              path: scenario.destination,
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => context.replace('/replacement'),
                  child: const Text('replace child'),
                ),
              ),
            ),
            GoRoute(
              path: '/replacement',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => context.pop(),
                  child: const Text('return source'),
                ),
              ),
            ),
          ],
        );
        final container = ProviderContainer(
          overrides: [
            apiClientProvider.overrideWithValue(api),
            sharedPreferencesProvider.overrideWithValue(preferences),
            masterNameServiceProvider.overrideWithValue(MasterNameService(api)),
            productionPlanRepositoryProvider.overrideWithValue(
              ProductionPlanRepository(api),
            ),
            isSuperAdminProvider.overrideWithValue(false),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.productionPlanView,
              Perm.productionPlanApprove,
              Perm.productionMaterialAnalysisView,
            }),
          ],
        );
        final detach = attachPageResume(
          router,
          container.read(pageResumeProvider.notifier),
        );
        try {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(
                routerConfig: router,
                locale: const Locale('zh'),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final sourceState = tester.state(
            find.byType(sourceWidget.runtimeType),
          );
          Future<void> open() async {
            if (find.text(scenario.label).hitTestable().evaluate().isEmpty) {
              await tester.tap(
                find.byKey(const Key('uten-app-bar-more-actions')),
              );
              await tester.pumpAndSettle();
            }
            await tester.tap(find.text(scenario.label).hitTestable().last);
            await tester.pumpAndSettle();
            expect(find.text('replace child'), findsOneWidget);
          }

          await open();
          await tester.tap(find.text('replace child'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('return source'));
          await tester.pumpAndSettle();
          expect(
            tester.state(find.byType(sourceWidget.runtimeType)),
            same(sourceState),
          );
          expect(
            find.descendant(
              of: find.byType(UtenAppBar),
              matching: find.byType(CircularProgressIndicator),
            ),
            findsNothing,
            reason:
                'Pure navigation must not retain child route Future as header busy feedback.',
          );
          await open();
          expect(
            requests.where((request) => request.method != 'GET'),
            isEmpty,
            reason: 'Opening a header link must not issue a business write.',
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          detach();
          router.dispose();
          container.dispose();
        }
      },
    );
  }
}

ApiClient _api(List<RequestOptions> requests) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) {
        requests.add(request);
        final Object data = switch (request.path) {
          '/master/warehouses/dict' => [
            {
              'id': 'warehouse-1',
              'name': '主仓',
              'code': '001',
              'selectableForNew': true,
            },
          ],
          '/production/material-analyses/analysis-1' => {
            'analysisId': 'analysis-1',
            'version': 1,
            'fingerprint': 'a' * 64,
            'warehouseId': 'warehouse-1',
            'warehouseIds': ['warehouse-1'],
            'status': 'ACTIVE',
            'allowedActions': ['VIEW'],
            'products': <Object>[],
            'materials': <Object>[],
            'sources': <Object>[],
          },
          '/production/plans' || '/production/material-analyses' => {
            'items': <Object>[],
            'page': 1,
            'size': 20,
            'total': 0,
            'totalPages': 1,
          },
          _ =>
            request.path.endsWith('/dict') ||
                    request.path.endsWith('/tree') ||
                    request.path.endsWith('/future-transfers') ||
                    request.path.endsWith('/workshop-urges') ||
                    request.path.endsWith('/default-workshops')
                ? <Object>[]
                : <String, Object>{},
        };
        handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: data,
          ),
        );
      },
    ),
  );
  return ApiClient(dio);
}
