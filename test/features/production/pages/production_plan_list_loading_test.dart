import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/production/models/production_plan.dart';
import 'package:uten_imp/features/production/pages/production_plan_list_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

final _reader = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader-a'),
);

void main() {
  for (final mode in _ResultMode.values) {
    testWidgets('plan ${mode.name} does not await a slow name dictionary', (
      tester,
    ) async {
      final api = _PlanApi(mode);
      await _mount(tester, api);
      expect(api.dictionaryPaths, isEmpty);
      await tester.tap(find.text('进行中'));
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      if (mode == _ResultMode.empty) {
        expect(find.text('暂无生产计划单'), findsOneWidget);
        expect(api.dictionaryPaths, isEmpty);
      } else {
        expect(find.text('SC-1'), findsOneWidget);
        expect(api.dictionaryPaths, [ApiEndpoints.departmentsTree]);
        if (mode == _ResultMode.snapshots) {
          expect(find.text('随行车间'), findsOneWidget);
          expect(find.text('随行跟单员'), findsOneWidget);
          expect(api.employeeCalls, 0);
        }
      }
      api.completeNames();
      await tester.pumpAndSettle();
      if (mode == _ResultMode.legacyFallbacks) {
        expect(find.text('字典车间'), findsOneWidget);
        expect(find.text('补全跟单员'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late optional names cannot restore a retired plan reader', (
    tester,
  ) async {
    final api = _PlanApi(_ResultMode.legacyFallbacks);
    final container = await _mount(tester, api);
    await tester.tap(find.text('进行中'));
    await tester.pumpAndSettle();
    expect(find.text('SC-1'), findsOneWidget);
    container.read(_reader.notifier).state = null;
    await tester.pumpAndSettle();
    expect(find.text('SC-1'), findsNothing);
    api.completeNames();
    await tester.pumpAndSettle();
    expect(find.text('SC-1'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<ProviderContainer> _mount(WidgetTester tester, _PlanApi api) async {
  await tester.binding.setSurfaceSize(const Size(1500, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    initialLocation: '/production/plans',
    routes: [
      GoRoute(
        path: '/production/plans',
        builder: (_, _) => const ProductionPlanListPage(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentPermissionsProvider.overrideWithValue(const {}),
        isSuperAdminProvider.overrideWithValue(false),
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(_reader)),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  expect(
    find.byType(MasterDataTableView<ProductionPlanListItem>),
    findsOneWidget,
  );
  return ProviderScope.containerOf(
    tester.element(find.byType(ProductionPlanListPage)),
  );
}

enum _ResultMode { empty, snapshots, legacyFallbacks }

class _PlanApi extends ApiClient {
  _PlanApi(this.mode) : super(Dio());

  final _ResultMode mode;
  final dictionaryPaths = <String>[];
  final departments = Completer<List<Map<String, dynamic>>>();
  final employee = Completer<Map<String, dynamic>>();
  int employeeCalls = 0;

  void completeNames() {
    departments.complete([
      {'id': 'dept-1', 'name': '字典车间'},
    ]);
    employee.complete({'id': 'seller-1', 'fullName': '补全跟单员'});
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == '/production/plans') {
      return {
        'items': [
          if (mode != _ResultMode.empty)
            {
              'id': 'plan-1',
              'billNo': 'SC-1',
              'departmentId': 'dept-1',
              'sellerId': 'seller-1',
              'status': 1,
              if (mode == _ResultMode.snapshots) ...{
                'workshopName': '随行车间',
                'sellerName': '随行跟单员',
              },
            },
        ],
        'page': 1,
        'total': mode == _ResultMode.empty ? 0 : 1,
        'totalPages': mode == _ResultMode.empty ? 0 : 1,
      };
    }
    if (path == ApiEndpoints.employee('seller-1')) {
      employeeCalls++;
      return employee.future;
    }
    return {};
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) {
    dictionaryPaths.add(path);
    return departments.future;
  }
}
