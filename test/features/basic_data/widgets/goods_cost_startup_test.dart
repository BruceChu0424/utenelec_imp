import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/memory_form_draft_storage.dart';
import 'package:uten_imp/features/basic_data/models/currency_node.dart';
import 'package:uten_imp/features/basic_data/models/goods_cost_sheet.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/repositories/currency_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_cost_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_cost_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _StartupCosts extends Fake implements GoodsCostRepository {
  bool confirmed = false;
  int previews = 0, saves = 0;
  int productionCalls = 0;
  @override
  Future<Map<String, dynamic>> productionOutput(
    String goodsId, {
    String? executionSegmentId,
  }) async {
    productionCalls++;
    return {'state': 'NONE', 'goodsId': goodsId};
  }

  Map<String, dynamic>? previewInput;
  GoodsCostCalculation get result => GoodsCostCalculation({
    'lines': <Object>[],
    'fees': <Object>[],
    'issues': <Object>[],
    'totals': {'valueState': 'COMPLETE', 'knownTotal': '10', 'unitCost': '2'},
  });
  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async => [
    {'id': 'sheet'},
  ];
  @override
  Future<List<Map<String, dynamic>>> templates(
    String goodsId,
    String? clientId,
  ) async => [];
  @override
  Future<GoodsCostSheet> detail(String id) async => GoodsCostSheet({
    'id': 'sheet',
    'version': 7,
    'sheetNo': 'CB0001',
    'status': confirmed ? 'CONFIRMED' : 'DRAFT',
    'canEdit': !confirmed,
    'canConfirm': false,
    'canExport': false,
    'input': {
      'goodsId': 'goods',
      'name': '成本单',
      'batchQty': '5',
      'exchangeRateToLocal': '1',
      'priceStrategy': 'MANUAL',
      'usageStrategy': 'DESIGN',
      'lineOverrides': [
        {
          'path': 'kept-path',
          'adoptedQty': '0.123456',
          'unitPrice': '20',
          'reason': 'kept override',
        },
      ],
    },
    'calculation': result.json,
  });
  @override
  Future<GoodsCostCalculation> preview(Map<String, dynamic> input) async {
    previews++;
    previewInput = copyCostJson(input);
    return result;
  }

  @override
  Future<GoodsCostSheet> save(
    String? id,
    Map<String, dynamic> input, {
    required String idempotencyKey,
    int? expectedVersion,
  }) async {
    saves++;
    expect(id, 'sheet');
    expect(expectedVersion, 7);
    throw ApiException('VALIDATION_ERROR', '测算数量必须大于零');
  }
}

class _StartupCurrencies extends Fake implements CurrencyRepository {
  @override
  Future<List<CurrencyListItem>> dict() async => [];
}

class _BootstrapCosts extends _StartupCosts {
  int lists = 0, bootstraps = 0;
  bool rejectFirstList = false;
  Completer<List<Map<String, dynamic>>>? pendingList;

  @override
  Future<List<Map<String, dynamic>>> list(String goodsId) async {
    lists++;
    if (rejectFirstList && lists == 1) {
      throw ApiException('UNAVAILABLE', '成本暂时无法读取');
    }
    return pendingList?.future ?? [];
  }

  @override
  Future<GoodsCostCalculation> bootstrap(
    String goodsId, {
    String? clientId,
  }) async {
    bootstraps++;
    return GoodsCostCalculation({
      ...result.json,
      'resolvedInput': {
        'goodsId': goodsId,
        'name': '服务端默认预算',
        'batchQty': '23',
        'usageStrategy': 'DESIGN',
        'priceStrategy': 'MANUAL',
      },
    });
  }
}

class _RejectedResetStorage extends MemoryFormDraftStorage
    implements BusinessResetFormDraftStorage {
  int attempts = 0;
  @override
  Future<void> synchronizeBusinessReset(
    String ownerPrefix,
    int generation,
  ) async {
    attempts++;
    throw StateError('业务数据已清空，请重新登录后使用草稿');
  }
}

Future<void> _pump(
  WidgetTester tester,
  _StartupCosts costs, {
  FormDraftStorage? storage,
  AuthenticatedScope? scope,
  String? resumeId,
}) async {
  await tester.binding.setSurfaceSize(const Size(1200, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  const home = Scaffold(
    body: GoodsCostTab(
      detail: GoodsDetail(id: 'goods', name: '货品'),
      canEdit: true,
    ),
  );
  final router = resumeId == null
      ? null
      : GoRouter(
          initialLocation: '/basicinfo/goods/goods?tab=cost&draftId=$resumeId',
          routes: [
            GoRoute(path: '/basicinfo/goods/:id', builder: (_, _) => home),
          ],
        );
  if (router != null) addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        goodsCostRepositoryProvider.overrideWithValue(costs),
        currencyRepositoryProvider.overrideWithValue(_StartupCurrencies()),
        sharedPreferencesProvider.overrideWithValue(prefs),
        authenticatedScopeProvider.overrideWithValue(scope),
        apiBaseUrlProvider.overrideWithValue('https://cost-startup/api'),
        if (storage != null)
          formDraftStorageProvider.overrideWithValue(storage),
        currentPermissionsProvider.overrideWithValue({
          Perm.goodsView,
          Perm.goodsCostView,
          Perm.goodsCostEdit,
        }),
      ],
      child: router == null
          ? const MaterialApp(
              locale: Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: home,
            )
          : MaterialApp.router(
              locale: const Locale('zh'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              routerConfig: router,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'an explicitly resumed draft stays blocked by the real reset fence',
    (tester) async {
      final costs = _BootstrapCosts();
      await _pump(
        tester,
        costs,
        storage: _RejectedResetStorage(),
        scope: const AuthenticatedScope(userId: 'owner'),
        resumeId: 'old-draft',
      );
      expect(costs.bootstraps, 0);
      expect(costs.previews, 0);
      expect(find.text('这份草稿暂时无法恢复，原草稿已保留。'), findsOneWidget);
      expect(costs.saves, 0);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'local reset fence cannot stop the first authoritative cost bootstrap',
    (tester) async {
      final costs = _BootstrapCosts();
      final storage = _RejectedResetStorage();
      await _pump(
        tester,
        costs,
        storage: storage,
        scope: const AuthenticatedScope(userId: 'owner'),
      );
      expect(costs.bootstraps, 1);
      expect(costs.previews, 0);
      expect(storage.attempts, greaterThanOrEqualTo(1));
      expect(find.text('业务数据已清空，请重新登录后使用草稿'), findsNothing);
      await tester.tap(find.byKey(const Key('cost-settings-toggle')));
      await tester.pumpAndSettle();
      final quantity = tester.widget<TextFormField>(
        find.byKey(const ValueKey('cost-header-batchQty')),
      );
      expect(quantity.controller!.text, '23');
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costs.saves, 0);
      expect(find.text('业务数据已清空，请重新登录后使用草稿'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('startup retry repeats the authoritative load and bootstrap', (
    tester,
  ) async {
    final costs = _BootstrapCosts()..rejectFirstList = true;
    await _pump(tester, costs);
    expect(find.text('成本暂时无法读取'), findsOneWidget);
    expect(costs.bootstraps, 0);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(costs.lists, 2);
    expect(costs.bootstraps, 1);
    expect(costs.previews, 0);
    expect(find.text('成本暂时无法读取'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'opening a draft recalculates automatically with its own explicit strategy and overrides',
    (tester) async {
      final costs = _StartupCosts();
      await _pump(tester, costs);
      expect(costs.previews, 1);
      expect(costs.saves, 0);
      expect(costs.previewInput?['batchQty'], '5');
      expect(costs.previewInput?['priceStrategy'], 'MANUAL');
      expect(costs.previewInput?['usageStrategy'], 'DESIGN');
      expect(
        costMaps(costs.previewInput?['lineOverrides']).single['adoptedQty'],
        '0.123456',
      );
      expect(
        costMaps(costs.previewInput?['lineOverrides']).single['unitPrice'],
        '20',
      );
      expect(find.text('检查并重算'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'startup confirmed cost is read-only without recomputing historical evidence',
    (tester) async {
      final costs = _StartupCosts()..confirmed = true;
      await _pump(tester, costs);
      expect(costs.previews, 0);
      expect(costs.productionCalls, 0);
      expect(find.byKey(const Key('cost-production-summary')), findsNothing);
      expect(find.byKey(const Key('cost-save')), findsNothing);
      expect(find.byKey(const ValueKey('cost-header-batchQty')), findsNothing);
      await tester.tap(find.byKey(const Key('cost-settings-toggle')));
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byKey(const ValueKey('cost-header-batchQty')),
        matching: find.byType(TextField),
      );
      expect(tester.widget<TextField>(input).readOnly, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'cost save validation retains entered quantity and reports the server reason',
    (tester) async {
      final costs = _StartupCosts();
      await _pump(tester, costs);
      await tester.tap(find.byKey(const Key('cost-settings-toggle')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('cost-header-batchQty')),
        '-1',
      );
      await tester.ensureVisible(find.byKey(const Key('cost-save')));
      await tester.tap(find.byKey(const Key('cost-save')));
      await tester.pumpAndSettle();
      expect(costs.saves, 1);
      expect(find.text('测算数量必须大于零'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(
              find.byKey(const ValueKey('cost-header-batchQty')),
            )
            .controller!
            .text,
        '-1',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
