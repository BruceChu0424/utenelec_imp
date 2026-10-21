import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_material_market_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/pricing/material_market_models.dart';
import 'package:uten_imp/shared/pricing/material_market_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../../support/audit_screenshot_support.dart';

const _permissions = {
  Perm.goodsView,
  Perm.goodsPriceAnalysisView,
  Perm.purchaseOrderView,
  Perm.purchaseOrderPriceView,
  Perm.goodsEdit,
};
final _grants = StateProvider<Set<String>>((_) => _permissions);
final _scope = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'reader'),
);
final _goods = StateProvider<String>((_) => 'a');
final _conditions = StateProvider<String>((_) => 'purchase-90');
final _time = StateProvider<DateTime>((_) => DateTime.utc(2026, 10, 20, 9));

class _Snapshots extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async =>
      ref.watch(authenticatedScopeProvider) == null ? null : SessionSnapshot();
}

Map<String, dynamic> _benchmark({String id = 'copper'}) => {
  'seriesId': id,
  'name': switch (id) {
    'shfe_cu_main_daily' => '沪铜主力(日终)',
    'shfe_al_main_daily' => '沪铝主力(日终)',
    'shfe_ag_main_daily' => '沪银主力(日终)',
    _ => '铜现货参考',
  },
  'commodity': id == 'shfe_ag_main_daily'
      ? 'SILVER'
      : id == 'shfe_al_main_daily'
      ? 'ALUMINIUM'
      : 'COPPER',
  'market': id.startsWith('shfe_') ? 'FUTURES' : 'SPOT',
  'grade': '交易所标准',
  'region': '上海',
  'currency': 'CNY',
  'unit': id == 'shfe_ag_main_daily' ? '千克' : '吨',
  'priceBasis': '主力合约日终结算价',
  'sourceName': '上海期货交易所公开统计',
  'provider': 'SHFE_PUBLIC_DAILY',
  'autoUpdate': true,
  'selectable': true,
};

Map<String, dynamic> _snapshot({String id = 'copper'}) => {
  'schemaVersion': 1,
  'seriesId': id,
  'name': '铜现货参考',
  'commodity': 'COPPER',
  'market': 'SPOT',
  'grade': 'T1',
  'region': '华东',
  'currency': 'CNY',
  'unit': '吨',
  'priceBasis': '含税现货',
  'sourceName': '授权行情文件',
  'authorized': true,
  'dataAsOf': '2026-10-19',
  'generatedAt': '2026-10-20T08:00:00Z',
  'latestPrice': '81234.123456789',
  'status': 'READY',
  'modelVersion': 'statsforecast-v1',
  'libraryVersion': '2.0.3',
  'datasetDigest': 'sha256:aabb',
  'validation': {
    'passed': true,
    'baselineMAE': '100',
    'modelMAE': '80',
    'folds': 12,
    'coverage80': '0.83',
    'backtestStart': '2025-01-01',
    'backtestEnd': '2026-10-19',
  },
  'forecasts': [
    for (final horizon in [1, 5, 20])
      {
        'horizon': horizon,
        'price': '83000',
        'lower80': '82000',
        'upper80': '85000',
        'direction': 'UP',
      },
  ],
  'procurementSignal': 'RISING',
};

Map<String, dynamic> _researchSnapshot() => {
  ..._snapshot(id: 'shfe_cu_main_daily'),
  'schemaVersion': 2,
  'name': '沪铜主力(日终)',
  'market': 'FUTURES',
  'sourceName': '上海期货交易所公开统计',
  'status': 'RESEARCH_ONLY',
  'validationBasis': 'LATEST_HISTORY_REPLAY',
  'modelPriceBasis': 'CHAIN_LINKED_CURRENT_ANCHOR',
  'quoteContract': 'cu2611',
  'sourceFetchedAt': '2026-10-20T08:30:00Z',
  'historyRecordCount': 500,
  'procurementSignal': 'INSUFFICIENT',
};

Map<String, dynamic> _delayedQuote({
  String status = 'CURRENT',
  String expiresAt = '2026-10-20T09:20:00Z',
}) => {
  'schemaVersion': 1,
  'seriesId': 'shfe_cu_main_daily',
  'contract': 'cu2611',
  'price': '81400.123456789',
  'currency': 'CNY',
  'unit': '吨',
  'marketTime': '2026-10-20T08:00:00Z',
  'fetchedAt': '2026-10-20T08:40:00Z',
  'delayMinutes': 30,
  'provider': 'SHFE_PUBLIC_DAILY',
  'status': status,
  'expiresAt': expiresAt,
};

MaterialMarketAnalysis _analysis({
  String status = 'READY',
  String? seriesId = 'copper',
  int version = 3,
  bool canManage = true,
  Map<String, dynamic>? snapshot,
  String? expiresAt = '2026-10-21T08:00:00Z',
  bool hasSnapshot = true,
  Map<String, dynamic>? sync,
  Map<String, dynamic>? latestQuote,
  int? refreshAfterSeconds,
}) => MaterialMarketAnalysis({
  'status': status,
  'seriesId': seriesId,
  'bindingVersion': version,
  'current': seriesId == null || !hasSnapshot
      ? null
      : snapshot ?? _snapshot(id: seriesId),
  'benchmark': seriesId == null ? null : _benchmark(id: seriesId),
  'sync': sync ?? {'status': 'OFFLINE', 'autoUpdateEnabled': false},
  'latestQuote': latestQuote,
  'refreshAfterSeconds': refreshAfterSeconds,
  'canManage': canManage,
  'expiresAt': expiresAt,
});

class _Repository implements MaterialMarketRepository {
  MaterialMarketAnalysis response = _analysis();
  List<MaterialMarketBenchmark> choices = [
    MaterialMarketBenchmark(_benchmark()),
  ];
  final reads = <String>[];
  final pending = <Completer<MaterialMarketAnalysis>>[];
  final writes = <Map<String, dynamic>>[];
  final pendingCatalogs = <Completer<List<MaterialMarketBenchmark>>>[];
  final pendingWrites = <Completer<MaterialMarketAnalysis>>[];
  bool fail = false, delay = false, delayCatalog = false, failWrite = false;
  bool delayWrite = false;
  bool bindPending = false;

  @override
  Future<MaterialMarketAnalysis> analysis(String goodsId) async {
    reads.add(goodsId);
    if (fail) throw StateError('unavailable');
    if (delay) {
      final pendingRead = Completer<MaterialMarketAnalysis>();
      pending.add(pendingRead);
      return pendingRead.future;
    }
    return response;
  }

  @override
  Future<List<MaterialMarketBenchmark>> catalog(String goodsId) async {
    if (delayCatalog) {
      final pendingRead = Completer<List<MaterialMarketBenchmark>>();
      pendingCatalogs.add(pendingRead);
      return pendingRead.future;
    }
    return choices;
  }

  @override
  Future<MaterialMarketAnalysis> bind(
    String goodsId, {
    required String? seriesId,
    required int expectedVersion,
  }) async {
    writes.add({
      'goodsId': goodsId,
      'seriesId': seriesId,
      'expectedVersion': expectedVersion,
    });
    if (failWrite) throw StateError('write result unknown');
    if (delayWrite) {
      final command = Completer<MaterialMarketAnalysis>();
      pendingWrites.add(command);
      return command.future;
    }
    return response = _analysis(
      status: seriesId == null
          ? 'UNMAPPED'
          : bindPending
          ? 'SYNC_PENDING'
          : 'READY',
      seriesId: seriesId,
      version: expectedVersion + 1,
      hasSnapshot: !bindPending,
      refreshAfterSeconds: bindPending ? 60 : null,
    );
  }
}

void main() {
  setUp(() {
    final previous = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = previous);
  });

  // A pending network request intentionally animates the shared action button.
  // Advance bounded frames without waiting for that progress to stop.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    await tester.pump();
  }

  Future<ProviderContainer> pump(
    WidgetTester tester,
    _Repository repository, {
    Size size = const Size(1100, 1000),
    bool dark = false,
    double textScale = 1,
    Locale locale = const Locale('zh'),
    GlobalKey? visualVariant,
  }) async {
    await loadAuditScreenshotFonts(tester);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          materialMarketRepositoryProvider.overrideWithValue(repository),
          materialMarketClockProvider.overrideWith(
            (ref) =>
                () => ref.read(_time),
          ),
          currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
          authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
          sessionSnapshotProvider.overrideWith(_Snapshots.new),
          isSuperAdminProvider.overrideWithValue(false),
          apiBaseUrlProvider.overrideWithValue('https://example.invalid/api'),
        ],
        child: RepaintBoundary(
          key: visualVariant ?? const Key('material-market-test-host'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: auditScreenshotTheme(
              dark ? buildDarkTheme() : buildLightTheme(),
            ),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(textScale)),
              child: UtenControlTheme(child: child!),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: Consumer(
                  builder: (context, ref, _) => Column(
                    children: [
                      const Text('历史成交参考 12.34'),
                      GoodsMaterialMarketPanel(
                        goodsId: ref.watch(_goods),
                        contextIdentity: ref.watch(_conditions),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
  }

  Future<void> choose(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('material-market-link')));
    await settle(tester);
    final title = find.descendant(
      of: find.byKey(const ValueKey('material-market-choice-copper')),
      matching: find.text('铜现货参考'),
    );
    await tester.ensureVisible(title);
    await settle(tester);
    await tester.tap(title);
    await settle(tester);
  }

  testWidgets('optional snapshot failure keeps historical reference usable', (
    tester,
  ) async {
    final repository = _Repository()..fail = true;
    final visualVariant = GlobalKey();
    await pump(tester, repository, visualVariant: visualVariant);
    expect(find.text('历史成交参考 12.34'), findsOneWidget);
    expect(find.byKey(const Key('material-market-error')), findsOneWidget);
    expect(find.byKey(const Key('material-market-quote')), findsNothing);
    repository.fail = false;
    await tester.tap(find.byKey(const Key('material-market-refresh')));
    await settle(tester);
    expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
    expect(find.textContaining('81234.123456789'), findsOneWidget);
    expect(repository.writes, isEmpty);
    const capture = bool.fromEnvironment('UTEN_MATERIAL_VISUALS');
    if (capture) {
      await saveAuditScreenshot(tester, visualVariant, 'material-market-wide');
    }
  });

  testWidgets(
    'unconfigured state explains automatic service connection without CSV maintenance',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(
          status: 'DISABLED',
          seriesId: null,
          canManage: false,
        );
      await pump(tester, repository);
      expect(find.textContaining('自动行情服务尚未连接'), findsOneWidget);
      expect(find.textContaining('CSV'), findsNothing);
      expect(find.byKey(const Key('material-market-link')), findsNothing);
      expect(find.byKey(const Key('material-market-quote')), findsNothing);
      expect(find.textContaining('未来 1 个观测期'), findsNothing);
    },
  );

  testWidgets(
    'selection is staged; cancel sends no write; confirm uses binding CAS',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null, version: 0);
      await pump(tester, repository);
      await choose(tester);
      expect(repository.writes, isEmpty);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(repository.writes, isEmpty);
      await choose(tester);
      await tester.tap(find.byKey(const Key('material-market-picker-confirm')));
      await settle(tester);
      expect(repository.writes, [
        {'goodsId': 'a', 'seriesId': 'copper', 'expectedVersion': 0},
      ]);
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
    },
  );

  testWidgets('unlink requires explicit confirmation and keeps tombstone CAS', (
    tester,
  ) async {
    final repository = _Repository();
    await pump(tester, repository);
    await tester.tap(find.byKey(const Key('material-market-unlink')));
    await settle(tester);
    await tester.tap(find.text('取消'));
    await settle(tester);
    expect(repository.writes, isEmpty);
    await tester.tap(find.byKey(const Key('material-market-unlink')));
    await settle(tester);
    await tester.tap(find.byKey(const Key('material-market-unlink-confirm')));
    await settle(tester);
    expect(repository.writes, [
      {'goodsId': 'a', 'seriesId': null, 'expectedVersion': 3},
    ]);
    expect(find.byKey(const Key('material-market-quote')), findsNothing);
  });

  testWidgets(
    'empty catalog explains unavailable definitions and cannot confirm a fake choice',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null)
        ..choices = [];
      await pump(tester, repository);
      await tester.tap(find.byKey(const Key('material-market-link')));
      await settle(tester);
      expect(
        find.byKey(const Key('material-market-empty-catalog')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('material-market-picker-confirm')));
      await settle(tester);
      expect(repository.writes, isEmpty);
    },
  );

  testWidgets(
    'stale snapshot preserves dated quote but suppresses forecasts and signal',
    (tester) async {
      await pump(tester, _Repository()..response = _analysis(status: 'STALE'));
      expect(find.textContaining('行情已过期'), findsOneWidget);
      expect(find.textContaining('2026-10-19'), findsWidgets);
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
      expect(find.byKey(const Key('material-market-horizon-1')), findsNothing);
      expect(find.byKey(const Key('material-market-signal')), findsNothing);
    },
  );

  testWidgets(
    'baseline failure is not presented as validated direction or purchase signal',
    (tester) async {
      final snapshot = {
        ..._snapshot(),
        'status': 'BASELINE_ONLY',
        'validation': {'passed': false},
      };
      await pump(
        tester,
        _Repository()
          ..response = _analysis(status: 'BASELINE_ONLY', snapshot: snapshot),
      );
      expect(find.text('未来基线估计'), findsOneWidget);
      expect(find.text('方向不明'), findsNWidgets(3));
      expect(find.byKey(const Key('material-market-signal')), findsNothing);
      expect(find.text('已通过历史回测'), findsNothing);
    },
  );

  testWidgets('read-only identity cannot manage a server-manageable binding', (
    tester,
  ) async {
    final container = await pump(tester, _Repository());
    container.read(_scope.notifier).state = const AuthenticatedScope(
      userId: 'reader',
      readOnly: true,
    );
    await settle(tester);
    expect(find.byKey(const Key('material-market-link')), findsNothing);
    expect(find.byKey(const Key('material-market-unlink')), findsNothing);
  });

  testWidgets(
    'finance source and commercial alternatives retain authorized market access',
    (tester) async {
      final repository = _Repository();
      final container = await pump(tester, repository);
      container.read(_grants.notifier).state = {
        Perm.goodsView,
        Perm.goodsPriceAnalysisView,
        Perm.financeOrderApprovalView,
        Perm.financeViewAll,
      };
      await settle(tester);
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
      expect(repository.reads, hasLength(2));
      container.read(_grants.notifier).state = {Perm.goodsView};
      await settle(tester);
      expect(find.byKey(const Key('material-market-quote')), findsNothing);
    },
  );

  testWidgets(
    'server canManage remains authoritative for settings visibility',
    (tester) async {
      await pump(tester, _Repository()..response = _analysis(canManage: false));
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
      expect(find.byKey(const Key('material-market-link')), findsNothing);
      expect(find.byKey(const Key('material-market-unlink')), findsNothing);
    },
  );

  testWidgets('expiry hides the signal and refreshes the envelope once', (
    tester,
  ) async {
    final repository = _Repository()
      ..response = _analysis(expiresAt: '2026-10-20T09:00:30Z');
    final container = await pump(tester, repository);
    expect(find.byKey(const Key('material-market-signal')), findsOneWidget);
    repository.response = _analysis(status: 'STALE');
    container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 0, 31);
    await tester.pump(const Duration(seconds: 31));
    await settle(tester);
    expect(repository.reads, hasLength(2));
    expect(find.byKey(const Key('material-market-signal')), findsNothing);
    expect(find.byKey(const Key('material-market-horizon-1')), findsNothing);
    expect(find.textContaining('行情已过期'), findsOneWidget);
  });

  testWidgets(
    'expiry does not interrupt staged selection and refreshes after cancel',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(expiresAt: '2026-10-20T09:00:30Z');
      final container = await pump(tester, repository);
      await tester.tap(find.byKey(const Key('material-market-link')));
      await settle(tester);
      repository.response = _analysis(status: 'STALE');
      container.read(_time.notifier).state = DateTime.utc(
        2026,
        10,
        20,
        9,
        0,
        31,
      );
      await tester.pump(const Duration(seconds: 31));
      await settle(tester);
      expect(repository.reads, hasLength(1));
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(repository.reads, hasLength(2));
      expect(repository.writes, isEmpty);
      expect(find.byKey(const Key('material-market-signal')), findsNothing);
    },
  );

  testWidgets('background expiry waits for foreground before fetching', (
    tester,
  ) async {
    final repository = _Repository()
      ..response = _analysis(expiresAt: '2026-10-20T09:00:30Z');
    final container = await pump(tester, repository);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    repository.response = _analysis(status: 'STALE');
    container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 0, 31);
    await tester.pump(const Duration(seconds: 31));
    expect(repository.reads, hasLength(1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(repository.reads, hasLength(2));
    expect(find.byKey(const Key('material-market-signal')), findsNothing);
  });

  testWidgets('a panel first mounted in background reads only after resume', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    final repository = _Repository();
    await pump(tester, repository);
    expect(repository.reads, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
    expect(repository.reads, ['a']);
    expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
  });

  testWidgets('missing expiry fails closed even if an old server says READY', (
    tester,
  ) async {
    await pump(tester, _Repository()..response = _analysis(expiresAt: null));
    expect(find.byKey(const Key('material-market-signal')), findsNothing);
    expect(find.byKey(const Key('material-market-horizon-1')), findsNothing);
    expect(find.textContaining('行情已过期'), findsOneWidget);
  });

  testWidgets(
    'v2 built-ins can be linked once without a worker or snapshot then update by GET',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'DISABLED', seriesId: null, version: 0)
        ..bindPending = true
        ..choices = [
          for (final id in [
            'shfe_cu_main_daily',
            'shfe_al_main_daily',
            'shfe_ag_main_daily',
          ])
            MaterialMarketBenchmark(_benchmark(id: id)),
        ];
      final container = await pump(tester, repository);
      await tester.tap(find.byKey(const Key('material-market-link')));
      await settle(tester);
      expect(find.text('沪铜主力(日终)'), findsOneWidget);
      expect(find.text('沪铝主力(日终)'), findsOneWidget);
      expect(find.text('沪银主力(日终)'), findsOneWidget);
      expect(
        repository.choices.every((row) => !row.data.containsKey('latestPrice')),
        true,
      );
      await tester.tap(find.text('沪铜主力(日终)'));
      await settle(tester);
      await tester.tap(find.byKey(const Key('material-market-picker-confirm')));
      await settle(tester);
      expect(repository.writes, [
        {
          'goodsId': 'a',
          'seriesId': 'shfe_cu_main_daily',
          'expectedVersion': 0,
        },
      ]);
      expect(
        find.byKey(const Key('material-market-bound-benchmark')),
        findsOneWidget,
      );
      expect(find.textContaining('等待首次行情'), findsOneWidget);
      expect(find.textContaining('自动行情服务未连接'), findsOneWidget);
      expect(find.textContaining('CSV'), findsNothing);
      expect(find.byKey(const Key('material-market-quote')), findsNothing);
      repository.response = _analysis(
        status: 'RESEARCH_ONLY',
        seriesId: 'shfe_cu_main_daily',
        version: 1,
        snapshot: _researchSnapshot(),
        latestQuote: _delayedQuote(),
        refreshAfterSeconds: 60,
        sync: {
          'status': 'IDLE',
          'autoUpdateEnabled': true,
          'lastSuccessAt': '2026-10-20T09:01:00Z',
        },
      );
      container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 1);
      await tester.pump(const Duration(seconds: 60));
      await settle(tester);
      expect(find.text('自动更新已连接'), findsOneWidget);
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
      expect(
        find.byKey(const Key('material-market-delayed-quote')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('material-market-horizon-20')),
        findsOneWidget,
      );
      expect(repository.writes, hasLength(1));
    },
  );

  testWidgets(
    'v2 research replay shows direction without validated badge or purchasing signal',
    (tester) async {
      final visualVariant = GlobalKey();
      final repository = _Repository()
        ..response = _analysis(
          status: 'RESEARCH_ONLY',
          seriesId: 'shfe_cu_main_daily',
          snapshot: _researchSnapshot(),
          latestQuote: _delayedQuote(),
          refreshAfterSeconds: 60,
          sync: {
            'status': 'IDLE',
            'autoUpdateEnabled': true,
            'lastSuccessAt': '2026-10-20T08:40:00Z',
            'nextSyncAt': '2026-10-20T09:01:00Z',
          },
        );
      await pump(tester, repository, visualVariant: visualVariant);
      expect(find.text('历史回放研究预测'), findsOneWidget);
      expect(find.text('倾向上涨'), findsNWidgets(3));
      expect(find.text('已通过历史回测'), findsNothing);
      expect(find.byKey(const Key('material-market-signal')), findsNothing);
      expect(
        find.textContaining('最新延迟行情（至少 30 分钟）: 81400.123456789'),
        findsOneWidget,
      );
      expect(find.textContaining('最近日终结算: 81234.123456789'), findsOneWidget);
      expect(find.text('日终交易日: 2026-10-19'), findsOneWidget);
      expect(find.text('行情时间: 2026-10-20 16:00(北京)'), findsOneWidget);
      expect(find.text('读取时间: 2026-10-20 16:40(北京)'), findsOneWidget);
      expect(find.text('上次更新: 2026-10-20 16:40(北京)'), findsOneWidget);
      expect(find.text('下次检查: 2026-10-20 17:01(北京)'), findsOneWidget);
      const capture = bool.fromEnvironment('UTEN_MATERIAL_VISUALS');
      if (capture) {
        await saveAuditScreenshot(tester, visualVariant, 'material-market-v2-wide');
      }
      await tester.tap(find.byKey(const Key('material-market-evidence')));
      await settle(tester);
      expect(find.textContaining('历史回放 80% 区间覆盖比例: 83%'), findsOneWidget);
      expect(find.textContaining('当前主力合约价位'), findsOneWidget);
      expect(find.text('生成时间: 2026-10-20 16:00(北京)'), findsOneWidget);
      expect(find.text('日终数据读取时间: 2026-10-20 16:30(北京)'), findsOneWidget);
    },
  );

  for (final research in [false, true]) {
    testWidgets(
      'pending poll cannot extend snapshot or quote expiry (research=$research)',
      (tester) async {
        final repository = _Repository()
          ..response = _analysis(
            status: research ? 'RESEARCH_ONLY' : 'READY',
            seriesId: 'shfe_cu_main_daily',
            snapshot: research
                ? _researchSnapshot()
                : _snapshot(id: 'shfe_cu_main_daily'),
            expiresAt: '2026-10-20T09:01:10Z',
            latestQuote: _delayedQuote(expiresAt: '2026-10-20T09:01:10Z'),
            refreshAfterSeconds: 60,
          );
        final container = await pump(tester, repository);
        expect(
          find.byKey(const Key('material-market-horizon-1')),
          findsOneWidget,
        );
        if (!research) {
          expect(
            find.byKey(const Key('material-market-signal')),
            findsOneWidget,
          );
        }
        repository.delay = true;
        container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 1);
        await tester.pump(const Duration(seconds: 60));
        await settle(tester);
        expect(repository.pending, hasLength(1));
        expect(
          find.byKey(const Key('material-market-horizon-1')),
          findsOneWidget,
        );
        container.read(_time.notifier).state = DateTime.utc(
          2026,
          10,
          20,
          9,
          1,
          11,
        );
        await tester.pump(const Duration(seconds: 11));
        await settle(tester);
        expect(repository.pending.single.isCompleted, false);
        expect(
          find.byKey(const Key('material-market-horizon-1')),
          findsNothing,
        );
        expect(find.byKey(const Key('material-market-signal')), findsNothing);
        expect(
          find.byKey(const Key('material-market-delayed-stale')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
        expect(repository.reads, hasLength(2));
        expect(repository.writes, isEmpty);
        repository.pending.single.complete(
          _analysis(
            status: 'STALE',
            latestQuote: _delayedQuote(status: 'STALE'),
          ),
        );
        await settle(tester);
      },
    );
  }

  testWidgets(
    'v2 delayed quote expiry refreshes earlier than cadence and never changes settlement date',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(
          status: 'RESEARCH_ONLY',
          seriesId: 'shfe_cu_main_daily',
          snapshot: _researchSnapshot(),
          latestQuote: _delayedQuote(expiresAt: '2026-10-20T09:00:20Z'),
          refreshAfterSeconds: 60,
        );
      final container = await pump(tester, repository);
      repository.response = _analysis(
        status: 'RESEARCH_ONLY',
        seriesId: 'shfe_cu_main_daily',
        snapshot: _researchSnapshot(),
        latestQuote: _delayedQuote(
          status: 'STALE',
          expiresAt: '2026-10-20T09:00:20Z',
        ),
        refreshAfterSeconds: 60,
      );
      container.read(_time.notifier).state = DateTime.utc(
        2026,
        10,
        20,
        9,
        0,
        21,
      );
      await tester.pump(const Duration(seconds: 21));
      await settle(tester);
      expect(repository.reads, hasLength(2));
      expect(
        find.byKey(const Key('material-market-delayed-stale')),
        findsOneWidget,
      );
      expect(find.text('日终交易日: 2026-10-19'), findsOneWidget);
      expect(repository.writes, isEmpty);
    },
  );

  testWidgets(
    'v2 offline heartbeat never claims synchronization even with auto flag',
    (tester) async {
      await pump(
        tester,
        _Repository()
          ..response = _analysis(
            status: 'SYNC_PENDING',
            seriesId: 'shfe_cu_main_daily',
            hasSnapshot: false,
            expiresAt: null,
            refreshAfterSeconds: 60,
            sync: {'status': 'OFFLINE', 'autoUpdateEnabled': true},
          ),
      );
      expect(find.textContaining('自动行情服务未连接'), findsOneWidget);
      expect(find.textContaining('正在读取最新行情'), findsNothing);
      expect(find.text('自动更新已连接'), findsNothing);
      expect(find.textContaining('沪铜主力(日终)'), findsOneWidget);
    },
  );

  testWidgets(
    'v2 automatic GET failure retains authorized evidence and retries only reads',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(
          status: 'RESEARCH_ONLY',
          seriesId: 'shfe_cu_main_daily',
          snapshot: _researchSnapshot(),
          refreshAfterSeconds: 60,
          sync: {'status': 'FETCHING', 'autoUpdateEnabled': true},
        );
      final container = await pump(tester, repository);
      expect(find.text('正在读取最新行情'), findsOneWidget);
      repository.fail = true;
      container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 1);
      await tester.pump(const Duration(seconds: 60));
      await settle(tester);
      expect(repository.reads, hasLength(2));
      expect(find.byKey(const Key('material-market-error')), findsOneWidget);
      expect(find.byKey(const Key('material-market-quote')), findsOneWidget);
      expect(find.text('正在读取最新行情'), findsNothing);
      expect(find.text('暂无法核对自动更新状态，保留上次行情依据'), findsOneWidget);
      repository.fail = false;
      repository.delay = true;
      container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 2);
      await tester.pump(const Duration(seconds: 60));
      await settle(tester);
      expect(repository.reads, hasLength(3));
      expect(find.text('正在读取最新行情'), findsNothing);
      expect(find.text('暂无法核对自动更新状态，保留上次行情依据'), findsOneWidget);
      repository.pending.single.complete(repository.response);
      await settle(tester);
      expect(find.text('正在读取最新行情'), findsOneWidget);
      expect(find.text('暂无法核对自动更新状态，保留上次行情依据'), findsNothing);
      expect(repository.writes, isEmpty);
    },
  );

  testWidgets(
    'v2 polling pauses behind another page and resumes without rebinding',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(
          status: 'SYNC_PENDING',
          seriesId: 'shfe_cu_main_daily',
          hasSnapshot: false,
          expiresAt: null,
          refreshAfterSeconds: 60,
        );
      final container = await pump(tester, repository);
      final navigator = Navigator.of(
        tester.element(find.byKey(const Key('material-market-panel'))),
      );
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('其他页面')),
          ),
        ),
      );
      await settle(tester);
      container.read(_time.notifier).state = DateTime.utc(2026, 10, 20, 9, 1);
      await tester.pump(const Duration(seconds: 60));
      await settle(tester);
      expect(repository.reads, hasLength(1));
      navigator.pop();
      await settle(tester);
      expect(repository.reads, hasLength(2));
      expect(repository.writes, isEmpty);
    },
  );

  testWidgets('A B A goods transitions discard the first A response', (
    tester,
  ) async {
    final repository = _Repository()..delay = true;
    final container = await pump(tester, repository);
    expect(repository.pending, hasLength(1));
    container.read(_goods.notifier).state = 'b';
    await settle(tester);
    container.read(_goods.notifier).state = 'a';
    await settle(tester);
    expect(repository.pending, hasLength(3));
    repository.pending.first.complete(_analysis());
    repository.pending[1].complete(_analysis());
    await settle(tester);
    expect(find.byKey(const Key('material-market-quote')), findsNothing);
    repository.pending.last.complete(
      _analysis(status: 'UNMAPPED', seriesId: null),
    );
    await settle(tester);
    expect(find.text('尚未关联行情基准'), findsOneWidget);
  });

  for (final transition in ['permission', 'account', 'conditions', 'goods']) {
    testWidgets('pending catalog cannot mutate after $transition changes', (
      tester,
    ) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null)
        ..delayCatalog = true;
      final container = await pump(tester, repository);
      await tester.tap(find.byKey(const Key('material-market-link')));
      await settle(tester);
      switch (transition) {
        case 'permission':
          container.read(_grants.notifier).state = {Perm.goodsView};
        case 'account':
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'another',
          );
        case 'conditions':
          container.read(_conditions.notifier).state = 'purchase-30';
        case 'goods':
          container.read(_goods.notifier).state = 'b';
      }
      await settle(tester);
      repository.pendingCatalogs.single.complete(repository.choices);
      await settle(tester);
      expect(
        find.byKey(const ValueKey('material-market-choice-copper')),
        findsNothing,
      );
      expect(repository.writes, isEmpty);
    });
  }

  testWidgets(
    'unknown write result clears the old link and only retries a read',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null)
        ..failWrite = true;
      await pump(tester, repository);
      await choose(tester);
      await tester.tap(find.byKey(const Key('material-market-picker-confirm')));
      await settle(tester);
      expect(find.textContaining('关联结果尚未核实'), findsOneWidget);
      expect(repository.writes, hasLength(1));
      await tester.tap(find.byKey(const Key('material-market-refresh')));
      await settle(tester);
      expect(repository.writes, hasLength(1));
      expect(repository.reads, hasLength(2));
    },
  );

  testWidgets(
    'late successful save cannot publish the old goods market after navigation',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null)
        ..delayWrite = true;
      final container = await pump(tester, repository);
      await choose(tester);
      await tester.tap(find.byKey(const Key('material-market-picker-confirm')));
      await settle(tester);
      expect(repository.pendingWrites, hasLength(1));
      container.read(_goods.notifier).state = 'b';
      await settle(tester);
      repository.pendingWrites.single.complete(_analysis());
      await settle(tester);
      expect(find.byKey(const Key('material-market-quote')), findsNothing);
      expect(find.text('尚未关联行情基准'), findsOneWidget);
      expect(repository.writes.single['goodsId'], 'a');
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      'narrow large-text ${dark ? 'dark' : 'light'} layout and evidence remain usable',
      (tester) async {
        final visualVariant = GlobalKey();
        await pump(
          tester,
          _Repository()
            ..response = _analysis(
              status: 'RESEARCH_ONLY',
              seriesId: 'shfe_cu_main_daily',
              snapshot: _researchSnapshot(),
              latestQuote: _delayedQuote(),
              refreshAfterSeconds: 60,
              sync: {'status': 'IDLE', 'autoUpdateEnabled': true},
            ),
          size: const Size(375, 812),
          dark: dark,
          textScale: 1.8,
          visualVariant: visualVariant,
        );
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('material-market-horizon-20')),
          findsOneWidget,
        );
        const capture = bool.fromEnvironment('UTEN_MATERIAL_VISUALS');
        if (capture) {
          await saveAuditScreenshot(
            tester,
            visualVariant,
            'material-market-${dark ? 'dark' : 'light'}-large-top',
          );
        }
        await tester.ensureVisible(
          find.byKey(const Key('material-market-evidence')),
        );
        await tester.tap(find.byKey(const Key('material-market-evidence')));
        await settle(tester);
        expect(find.textContaining('模型 MAE: 80'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (capture) {
          await saveAuditScreenshot(
            tester,
            visualVariant,
            'material-market-${dark ? 'dark' : 'light'}-large',
          );
        }
      },
    );
  }

  testWidgets(
    'narrow 2x picker keeps staged selection, footer and close usable',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(status: 'UNMAPPED', seriesId: null);
      await pump(
        tester,
        repository,
        size: const Size(375, 812),
        textScale: 2,
        dark: true,
        locale: const Locale('en'),
      );
      await choose(tester);
      expect(tester.takeException(), isNull);
      expect(repository.writes, isEmpty);
      await tester.tap(find.byKey(const Key('material-market-picker-close')));
      await settle(tester);
      expect(repository.writes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
