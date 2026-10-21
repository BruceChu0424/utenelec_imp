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

MaterialMarketAnalysis _analysis({
  String status = 'READY',
  String? seriesId = 'copper',
  int version = 3,
  bool canManage = true,
  Map<String, dynamic>? snapshot,
  String? expiresAt = '2026-10-21T08:00:00Z',
}) => MaterialMarketAnalysis({
  'status': status,
  'seriesId': seriesId,
  'bindingVersion': version,
  'current': seriesId == null ? null : snapshot ?? _snapshot(id: seriesId),
  'canManage': canManage,
  'expiresAt': expiresAt,
});

class _Repository implements MaterialMarketRepository {
  MaterialMarketAnalysis response = _analysis();
  List<MaterialMarketSnapshot> choices = [MaterialMarketSnapshot(_snapshot())];
  final reads = <String>[];
  final pending = <Completer<MaterialMarketAnalysis>>[];
  final writes = <Map<String, dynamic>>[];
  final pendingCatalogs = <Completer<List<MaterialMarketSnapshot>>>[];
  final pendingWrites = <Completer<MaterialMarketAnalysis>>[];
  bool fail = false, delay = false, delayCatalog = false, failWrite = false;
  bool delayWrite = false;

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
  Future<List<MaterialMarketSnapshot>> catalog(String goodsId) async {
    if (delayCatalog) {
      final pendingRead = Completer<List<MaterialMarketSnapshot>>();
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
      status: seriesId == null ? 'UNMAPPED' : 'READY',
      seriesId: seriesId,
      version: expectedVersion + 1,
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
    GlobalKey? visualKey,
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
          key: visualKey ?? const Key('material-market-test-host'),
          child: MaterialApp(
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
    final visualKey = GlobalKey();
    await pump(tester, repository, visualKey: visualKey);
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
      await saveAuditScreenshot(tester, visualKey, 'material-market-wide');
    }
  });

  testWidgets(
    'unconfigured state explains authorized CSV import and no live feed',
    (tester) async {
      final repository = _Repository()
        ..response = _analysis(
          status: 'DISABLED',
          seriesId: null,
          canManage: false,
        );
      await pump(tester, repository);
      expect(find.textContaining('当前未接入实时行情源'), findsOneWidget);
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
    'empty catalog directs CSV import and cannot confirm a fake choice',
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
        final visualKey = GlobalKey();
        await pump(
          tester,
          _Repository(),
          size: const Size(375, 812),
          dark: dark,
          textScale: 1.8,
          visualKey: visualKey,
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
            visualKey,
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
            visualKey,
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
