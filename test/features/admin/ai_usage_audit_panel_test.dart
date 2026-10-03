import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/admin/models/ai_provider_models.dart';
import 'package:uten_imp/features/admin/pages/admin_ai_settings_page.dart';
import 'package:uten_imp/features/admin/repositories/ai_provider_repository.dart';
import 'package:uten_imp/features/admin/widgets/ai_provider_card.dart';
import 'package:uten_imp/features/admin/repositories/ai_usage_audit_repository.dart';
import 'package:uten_imp/features/admin/widgets/ai_usage_audit_panel.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

import '../ai_visual/ai_visual_support.dart';

void main() {
  testWidgets(
    'billing refreshes parent provider versions before the next provider command',
    (tester) async {
      final providers = _Providers();
      final repository = _Repository()
        ..afterSave = (values) =>
            providers.version = (values['version'] as int) + 1;
      await _pump(tester, repository, providers: providers);
      expect(
        tester
            .widget<AiProviderCard>(find.byType(AiProviderCard))
            .provider
            .version,
        7,
      );
      await _openBilling(tester);
      await _save(tester);
      expect(providers.reads, 2);
      final list = find
          .descendant(
            of: find.byKey(const ValueKey('ai-settings-list')),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(list).position.jumpTo(0);
      await tester.pumpAndSettle();
      final card = tester.widget<AiProviderCard>(find.byType(AiProviderCard));
      expect(card.provider.version, 8);
      card.onEnabledChanged(false);
      await tester.pumpAndSettle();
      expect(providers.enabledVersions, [8]);
      expect(repository.reads.length, greaterThanOrEqualTo(2));
    },
  );

  for (final boundary in ['server', 'account', 'permission']) {
    testWidgets(
      'parent $boundary boundary hides old providers and late refreshes',
      (tester) async {
        final providers = _Providers();
        final harness = await _pump(
          tester,
          _Repository(),
          providers: providers,
        );
        final pending = Completer<List<AiProviderConfig>>();
        providers.pending.add(pending.future);
        await tester.tap(find.byKey(const ValueKey('ai-settings-refresh')));
        await tester.pump();
        providers.name = 'New provider context';
        harness.change(boundary);
        await tester.pumpAndSettle();
        expect(find.text('测试 AI 服务'), findsNothing);
        pending.complete([
          AiProviderConfig.fromJson({
            'id': _providerId,
            'name': 'Late old provider',
            'version': 7,
          }),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('Late old provider'), findsNothing);
        if (boundary == 'permission') {
          expect(find.byType(AiProviderCard), findsNothing);
        }
      },
    );
  }

  for (final denied in ['list', 'usage']) {
    testWidgets('parent authoritative $denied denial clears cached providers', (
      tester,
    ) async {
      final providers = _Providers();
      await _pump(tester, _Repository(), providers: providers);
      expect(find.byType(AiProviderCard), findsOneWidget);
      final error = ApiException('FORBIDDEN', 'Denied', httpStatus: 403);
      if (denied == 'list') {
        providers.listError = error;
      } else {
        providers.usageError = error;
      }
      await tester.tap(find.byKey(const ValueKey('ai-settings-refresh')));
      await tester.pumpAndSettle();
      expect(find.byType(AiProviderCard), findsNothing);
      expect(find.text('测试 AI 服务'), findsNothing);
      expect(find.byKey(const ValueKey('ai-settings-add')), findsNothing);
    });
  }

  testWidgets('usage timestamps follow the platform Beijing display', (
    tester,
  ) async {
    await _pump(tester, _Repository());
    expect(find.textContaining('2026-10-03 20:00(北京)'), findsOneWidget);
    expect(find.textContaining('12:00:00Z'), findsNothing);
  });

  test('repository preserves filters and optimistic billing version', () async {
    final api = _Api();
    final repository = DioAiUsageAuditRepository(api);
    await repository.read(
      days: 90,
      page: 2,
      userId: 'employee-1',
      providerId: _providerId,
    );
    expect(api.path, '/admin/ai/usage-audit');
    expect(api.query, {
      'days': 90,
      'page': 2,
      'size': 20,
      'userId': 'employee-1',
      'providerId': _providerId,
    });
    await repository.billing(_providerId);
    expect(api.path, '/admin/ai/providers/$_providerId/billing');
    await repository.saveBilling(_providerId, {
      'version': 7,
      'billingMode': 'SUBSCRIPTION',
      'currency': null,
    });
    expect(api.path, '/admin/ai/providers/$_providerId/billing');
    expect(api.body, {
      'version': 7,
      'billingMode': 'SUBSCRIPTION',
      'currency': null,
    });
  });

  testWidgets('unknown cost stays unknown and currencies are never combined', (
    tester,
  ) async {
    final repository = _Repository()
      ..data = _data(
        costs: [
          {'basis': 'ACTUAL', 'currency': 'CNY', 'amount': '1.23'},
          {'basis': 'ESTIMATE', 'currency': 'USD', 'amount': '0.45'},
        ],
        unknown: 2,
      );
    await _pump(tester, repository);
    expect(find.text('实际费用：CNY 1.23'), findsOneWidget);
    expect(find.text('估算费用：USD 0.45'), findsOneWidget);
    expect(find.text('2 次调用费用待确认'), findsOneWidget);
    expect(find.textContaining('1.68'), findsNothing);
    expect(find.textContaining('0.00'), findsNothing);
    repository.data = _data(costs: [], unknown: 3);
    await tester.tap(find.byTooltip('刷新记录'));
    await tester.pumpAndSettle();
    expect(find.text('3 次调用费用待确认'), findsOneWidget);
    expect(find.textContaining('CNY'), findsNothing);
    expect(find.textContaining('0.00'), findsNothing);
  });

  testWidgets(
    'known query and document purposes have human labels and pending status',
    (tester) async {
      final l10n = lookupAppLocalizations(const Locale('zh'));
      final cases = {
        'query_goods_cost': l10n.aiAuditPurposeCost,
        'inventory_lookup': l10n.aiAuditPurposeStock,
        'query_client_credit': l10n.aiAuditPurposeCredit,
        'SALES_ORDER': l10n.aiAuditPurposeOrder,
        'SALES_QUOTE': l10n.aiAuditPurposeQuote,
        'EXPENSE_CLAIM': l10n.aiAuditPurposeExpense,
        'unknown_internal_code': l10n.aiAuditKindChat,
      };
      final repository = _Repository()..data = _data();
      repository.data['records'] = [
        for (final entry in cases.entries)
          {
            'id': entry.key,
            'question': '',
            'kind': 'ERP_CHAT',
            'intent': entry.key,
            'status': 'PENDING',
          },
      ];
      await _pump(tester, repository);
      for (final entry in cases.entries) {
        expect(
          find.text(l10n.aiAuditQuestionMissing(entry.value)),
          findsOneWidget,
        );
        expect(find.textContaining(entry.key), findsNothing);
      }
      expect(
        find.textContaining(l10n.aiAuditQueued),
        findsNWidgets(cases.length),
      );
    },
  );

  testWidgets(
    'expanded records display the historical provider and model snapshot',
    (tester) async {
      final repository = _Repository();
      final record = (repository.data['records'] as List).single as Map;
      record['providerNames'] = ['历史服务 A', '历史服务 B'];
      record['models'] = ['previous-model-1', 'previous-model-2'];
      await _pump(tester, repository);
      await tester.tap(find.text('原账号问题内容'));
      await tester.pumpAndSettle();
      final l10n = lookupAppLocalizations(const Locale('zh'));
      expect(
        find.text(l10n.aiAuditProviders('历史服务 A / 历史服务 B')),
        findsOneWidget,
      );
      expect(
        find.text(l10n.aiAuditModel('previous-model-1 / previous-model-2')),
        findsOneWidget,
      );
      expect(find.text(l10n.aiAuditProviders('测试 AI 服务')), findsNothing);
    },
  );

  testWidgets(
    'paging and filter changes use the selected scope and reset to page zero',
    (tester) async {
      final repository = _Repository()..data = _data(total: 41);
      await _pump(tester, repository);
      await tester.ensureVisible(find.byTooltip('下一页'));
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
      expect(repository.reads.last['page'], 1);
      await _select<int>(tester, '时间', '近 7 天');
      expect(repository.reads.last['days'], 7);
      expect(repository.reads.last['page'], 0);
      await _select<String>(tester, '使用人', '示例员工（E001）');
      expect(repository.reads.last['userId'], 'employee-1');
      expect(repository.reads.last['page'], 0);
      await _select<String>(tester, 'AI 服务', '测试 AI 服务');
      expect(repository.reads.last['providerId'], _providerId);
      expect(repository.reads.last['userId'], 'employee-1');
      await _select<String>(tester, '使用人', '全部员工');
      expect(repository.reads.last['userId'], isNull);
      expect(repository.reads.last['providerId'], _providerId);
    },
  );

  testWidgets('billing is manual and uses each returned optimistic version', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    expect(repository.saved, isEmpty);
    await _openBilling(tester);
    expect(repository.saved, isEmpty);
    await _enter(tester, '每百万输入 token 单价', '1.2500000001');
    await _enter(tester, '每百万输出 token 单价', '2.50');
    await _save(tester);
    expect(repository.saved.single.$1, _providerId);
    expect(repository.saved.single.$2, {
      'version': 7,
      'billingMode': 'METERED',
      'currency': 'CNY',
      'inputPerMillion': '1.2500000001',
      'outputPerMillion': '2.50',
    });
    await _save(tester);
    expect(repository.saved.last.$2['version'], 8);
    repository.saveError = ApiException(
      'CONFLICT',
      '计费设置已被其他管理员修改',
      httpStatus: 409,
    );
    await _save(tester);
    expect(repository.saved.last.$2['version'], 9);
    expect(find.text('计费设置已被其他管理员修改'), findsOneWidget);
    expect(repository.saved, hasLength(3));
    repository.saveError = null;
    repository.billingValue['version'] = 41;
    await tester.ensureVisible(find.byTooltip('重新读取计费设置'));
    await tester.tap(find.byTooltip('重新读取计费设置'));
    await tester.pumpAndSettle();
    await _save(tester);
    expect(repository.saved.last.$2['version'], 41);
  });

  testWidgets('billing rejects malformed prices without dispatching a write', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await _openBilling(tester);
    for (final price in [
      '-1',
      '1e3',
      '1.12345678901',
      '1000000.0000000001',
      '9999999',
      '',
    ]) {
      await _enter(tester, '每百万输入 token 单价', price);
      await _save(tester);
      expect(repository.saved, isEmpty, reason: price);
    }
    expect(find.text('请填写有效的输入、输出单价。'), findsOneWidget);
    await _enter(tester, '每百万输入 token 单价', '1000000.0000000000');
    await _save(tester);
    expect(repository.saved.single.$2['inputPerMillion'], '1000000.0000000000');
  });

  for (final status in [401, 403]) {
    testWidgets(
      'server $status clears audit filters and the open billing editor',
      (tester) async {
        final repository = _Repository();
        await _pump(tester, repository);
        await _openBilling(tester);
        expect(find.widgetWithText(FilledButton, '保存计费设置'), findsOneWidget);
        final pending = Completer<Map<String, dynamic>>();
        repository.pendingReads.add(pending.future);
        await tester.ensureVisible(find.byTooltip('刷新记录'));
        await tester.tap(find.byTooltip('刷新记录'));
        await tester.pump();
        pending.completeError(
          ApiException('FORBIDDEN', '当前账号不能读取记录', httpStatus: status),
        );
        await tester.pumpAndSettle();
        expect(find.text('当前账号不能读取记录'), findsOneWidget);
        expect(find.text('原账号问题内容'), findsNothing);
        expect(find.byType(DropdownButtonFormField<String>), findsNothing);
        expect(find.widgetWithText(FilledButton, '保存计费设置'), findsNothing);
        expect(repository.saved, isEmpty);
      },
    );
  }

  testWidgets('billing denial also hides previously visible audit data', (
    tester,
  ) async {
    final repository = _Repository();
    await _pump(tester, repository);
    await _openBilling(tester);
    repository.saveError = ApiException(
      'FORBIDDEN',
      '当前账号不能修改计费',
      httpStatus: 403,
    );
    await _save(tester);
    expect(find.text('当前账号不能修改计费'), findsOneWidget);
    expect(find.text('原账号问题内容'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsNothing);
  });

  testWidgets('an initial billing read failure has an explicit retry', (
    tester,
  ) async {
    final repository = _Repository()..billingError = NetworkException();
    await _pump(tester, repository);
    await _openBilling(tester);
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsNothing);
    repository.billingError = null;
    await tester.ensureVisible(find.byTooltip('重新读取计费设置'));
    await tester.tap(find.byTooltip('重新读取计费设置'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, '保存计费设置'), findsOneWidget);
    expect(repository.saved, isEmpty);
  });

  testWidgets(
    'billing denial invalidates an audit read that was already in flight',
    (tester) async {
      final repository = _Repository();
      await _pump(tester, repository);
      await _openBilling(tester);
      final pendingSave = Completer<Map<String, dynamic>>();
      repository.pendingSave = pendingSave;
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.pump();
      final pendingRead = Completer<Map<String, dynamic>>();
      repository.pendingReads.add(pendingRead.future);
      await tester.ensureVisible(find.byTooltip('刷新记录'));
      await tester.tap(find.byTooltip('刷新记录'));
      await tester.pump();
      pendingSave.completeError(
        ApiException('FORBIDDEN', '不可继续读取费用', httpStatus: 403),
      );
      await tester.pumpAndSettle();
      pendingRead.complete(_data(question: '拒绝后的迟到内容'));
      await tester.pumpAndSettle();
      expect(find.text('拒绝后的迟到内容'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '刷新记录',
              ),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final locale in ['en', 'ko']) {
    testWidgets(
      '$locale audit and billing use localized labels and fit 390 width',
      (tester) async {
        final repository = _Repository();
        await _pump(
          tester,
          repository,
          width: 390,
          height: 1100,
          screenshot: true,
          locale: Locale(locale),
        );
        final l10n = lookupAppLocalizations(Locale(locale));
        expect(find.text(l10n.aiAuditTitle), findsOneWidget);
        expect(find.text(l10n.aiAuditUnknownCost(1)), findsOneWidget);
        expect(find.text('使用记录与费用'), findsNothing);
        await tester.ensureVisible(find.text(l10n.aiAuditBillingTitle));
        await tester.tap(find.text(l10n.aiAuditBillingTitle));
        await tester.pumpAndSettle();
        await _select<String>(tester, l10n.aiAuditSelectProvider, '测试 AI 服务');
        expect(find.text(l10n.aiAuditInputPrice), findsOneWidget);
        expect(find.text(l10n.aiAuditSaveBilling), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (kCaptureUi) {
          await tester.ensureVisible(find.text(l10n.aiAuditSaveBilling));
          await tester.pumpAndSettle();
          await capture(tester, 'usage-billing-$locale-390');
        }
      },
    );
  }

  for (final boundary in [
    'account',
    'permission',
    'server',
    'snapshot',
    'readonly',
    'actor',
    'admin',
  ]) {
    testWidgets(
      '$boundary change hides existing questions and rejects a late read',
      (tester) async {
        final repository = _Repository();
        final harness = await _pump(tester, repository);
        expect(find.text('原账号问题内容'), findsOneWidget);
        final pending = Completer<Map<String, dynamic>>();
        repository.pendingReads.add(pending.future);
        await tester.tap(find.byTooltip('刷新记录'));
        await tester.pump();
        repository.data = _data(question: '新账号记录');
        harness.change(boundary);
        await tester.pumpAndSettle();
        expect(find.text('原账号问题内容'), findsNothing);
        pending.complete(_data(question: '旧请求迟到的私密问题'));
        await tester.pumpAndSettle();
        expect(find.text('旧请求迟到的私密问题'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'stale billing callback cannot send old values after a server switch',
    (tester) async {
      final repository = _Repository();
      final harness = await _pump(tester, repository);
      await _openBilling(tester);
      final save = tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '保存计费设置'))
          .onPressed!;
      harness.change('server');
      // A retained callback must be fenced even before the scheduled rebuild.
      save();
      await tester.pumpAndSettle();
      expect(repository.saved, isEmpty);
    },
  );

  testWidgets(
    'late billing save does not refresh another account or show success',
    (tester) async {
      final repository = _Repository();
      final harness = await _pump(tester, repository);
      await _openBilling(tester);
      final pending = Completer<Map<String, dynamic>>();
      repository.pendingSave = pending;
      await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.tap(find.widgetWithText(FilledButton, '保存计费设置'));
      await tester.pump();
      expect(repository.saved, hasLength(1));
      final readCount = repository.reads.length;
      harness.change('account');
      await tester.pumpAndSettle();
      pending.complete({
        'version': 8,
        'billingMode': 'METERED',
        'model': 'old-private-model',
      });
      await tester.pumpAndSettle();
      expect(repository.reads, hasLength(readCount + 1));
      expect(find.text('已保存，仅影响后续调用。'), findsNothing);
      expect(find.textContaining('old-private-model'), findsNothing);
    },
  );

  testWidgets('390 wide audit and inline billing render without overflow', (
    tester,
  ) async {
    await setCaptureView(tester, const Size(390, 1100));
    final repository = _Repository()
      ..data = _data(
        costs: [
          {'basis': 'ESTIMATE', 'currency': 'CNY', 'amount': '1.23'},
          {'basis': 'ACTUAL', 'currency': 'USD', 'amount': '0.45'},
        ],
        unknown: 2,
      );
    await _pump(tester, repository, width: 390, height: 1100, screenshot: true);
    await capture(tester, 'usage-audit-390');
    await _openBilling(tester);
    await tester.ensureVisible(find.widgetWithText(FilledButton, '保存计费设置'));
    await tester.pumpAndSettle();
    await capture(tester, 'usage-billing-390');
    expect(tester.takeException(), isNull);
  }, skip: !kCaptureUi);
}

const _providerId = '11111111-1111-4111-8111-111111111111';
const _originalScope = AuthenticatedScope(userId: 'admin-a');
final _scope = StateProvider<AuthenticatedScope?>((ref) => _originalScope);
final _server = StateProvider<String>((ref) => 'https://one.invalid/api');
final _permissions = StateProvider<Set<String>>(
  (ref) => {Perm.authorizationManage},
);
final _session = StateProvider<SessionState>((ref) => _admin());

SessionState _admin({String id = 'admin-a', bool superAdmin = true}) =>
    SessionState(
      status: AuthStatus.authenticated,
      user: AppUser(
        id: id,
        code: id,
        name: id,
        superAdmin: superAdmin,
        permissions: const [Perm.authorizationManage],
      ),
    );

class _Session extends SessionNotifier {
  @override
  SessionState build() => ref.watch(_session);
}

class _Snapshot extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => SessionSnapshot(generation: 1);
  void expire() => state = const AsyncLoading();
}

class _Harness {
  _Harness(this.container);
  final ProviderContainer container;
  void change(String boundary) {
    switch (boundary) {
      case 'account':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-b',
        );
        container.read(_session.notifier).state = _admin(id: 'admin-b');
      case 'permission':
        container.read(_permissions.notifier).state = {};
      case 'server':
        container.read(_server.notifier).state = 'https://two.invalid/api';
      case 'snapshot':
        (container.read(sessionSnapshotProvider.notifier) as _Snapshot)
            .expire();
      case 'readonly':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-a',
          readOnly: true,
        );
      case 'actor':
        container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'admin-a',
          actorId: 'actor',
        );
      case 'admin':
        container.read(_session.notifier).state = _admin(superAdmin: false);
    }
  }
}

Future<_Harness> _pump(
  WidgetTester tester,
  _Repository repository, {
  double width = 1000,
  double height = 1200,
  bool screenshot = false,
  Locale locale = const Locale('zh'),
  _Providers? providers,
}) async {
  await setCaptureView(tester, Size(width, height));
  var koreanFontLoaded = false;
  if (kCaptureUi && locale.languageCode == 'ko') {
    // Widget tests do not load the app's Windows Korean fallback by default.
    // This is test-only: no system font is added to the application assets.
    await tester.runAsync(() async {
      final font = File('C:/Windows/Fonts/malgun.ttf');
      if (await font.exists()) {
        final bytes = ByteData.sublistView(await font.readAsBytes());
        await (FontLoader('AuditKorean')..addFont(Future.value(bytes))).load();
        koreanFontLoaded = true;
      }
    });
  }
  final container = ProviderContainer(
    overrides: [
      ...await baseOverrides(),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      sessionProvider.overrideWith(_Session.new),
      sessionSnapshotProvider.overrideWith(_Snapshot.new),
      aiUsageAuditRepositoryProvider.overrideWithValue(repository),
      if (providers != null)
        aiProviderRepositoryProvider.overrideWithValue(providers),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: screenshot ? captureBoundary : null,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: _auditTheme(korean: koreanFontLoaded),
          home: providers != null
              ? const AdminAiSettingsPage()
              : Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: AiUsageAuditPanel(
                      providers: [
                        AiProviderConfig.fromJson({
                          'id': _providerId,
                          'name': '测试 AI 服务',
                          'model': 'fixture-model',
                        }),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Harness(container);
}

ThemeData _auditTheme({required bool korean}) {
  final base = captureTheme();
  if (!korean) return base;
  TextStyle font(TextStyle? style) => (style ?? const TextStyle()).copyWith(
    fontFamily: 'AuditKorean',
    fontFamilyFallback: const ['NotoSansSC'],
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(
      fontFamily: 'AuditKorean',
      fontFamilyFallback: const ['NotoSansSC'],
    ),
    primaryTextTheme: base.primaryTextTheme.apply(
      fontFamily: 'AuditKorean',
      fontFamilyFallback: const ['NotoSansSC'],
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: font(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: font(base.listTileTheme.subtitleTextStyle),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      labelStyle: font(
        base.inputDecorationTheme.labelStyle ?? base.textTheme.bodySmall,
      ),
      floatingLabelStyle: font(
        base.inputDecorationTheme.floatingLabelStyle ??
            base.textTheme.bodySmall,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: base.filledButtonTheme.style?.copyWith(
        textStyle: WidgetStatePropertyAll(
          font(base.filledButtonTheme.style?.textStyle?.resolve({})),
        ),
      ),
    ),
  );
}

Finder _dropdown<T>(String label) => find.byWidgetPredicate(
  (widget) =>
      widget is DropdownButtonFormField<T> &&
      widget.decoration.labelText == label,
);
Future<void> _select<T>(
  WidgetTester tester,
  String label,
  String choice,
) async {
  final target = _dropdown<T>(label);
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
  await tester.tap(find.text(choice).last);
  await tester.pumpAndSettle();
}

Future<void> _openBilling(WidgetTester tester) async {
  await tester.ensureVisible(find.text('计费方式与套餐额度'));
  await tester.tap(find.text('计费方式与套餐额度'));
  await tester.pumpAndSettle();
  await _select<String>(tester, '选择服务', '测试 AI 服务');
}

Future<void> _enter(WidgetTester tester, String label, String value) async {
  final field = find.byWidgetPredicate(
    (widget) => widget is TextField && widget.decoration?.labelText == label,
  );
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pump();
}

Future<void> _save(WidgetTester tester) async {
  final button = find.widgetWithText(FilledButton, '保存计费设置');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Map<String, dynamic> _data({
  String question = '原账号问题内容',
  int total = 1,
  List<Map<String, dynamic>> costs = const [],
  int unknown = 1,
}) => {
  'summary': {
    'uses': 3,
    'calls': 3,
    'costs': costs,
    'unknownCostCalls': unknown,
  },
  'users': [
    {
      'userId': 'employee-1',
      'name': '示例员工',
      'code': 'E001',
      'uses': 3,
      'calls': 3,
      'costs': <Map<String, dynamic>>[],
      'unknownCostCalls': 1,
    },
  ],
  'records': [
    {
      'id': 'job-1',
      'name': '示例员工',
      'code': 'E001',
      'question': question,
      'status': 'SUCCEEDED',
      'kind': 'ERP_CHAT',
      'createdAt': '2026-10-03T12:00:00Z',
      'calls': 1,
      'inputTokens': null,
      'outputTokens': null,
      'costs': <Map<String, dynamic>>[],
      'unknownCostCalls': 1,
    },
  ],
  'total': total,
};

class _Repository implements AiUsageAuditRepository {
  Map<String, dynamic> data = _data();
  final reads = <Map<String, dynamic>>[];
  final pendingReads = Queue<Future<Map<String, dynamic>>>();
  final saved = <(String, Map<String, dynamic>)>[];
  Object? saveError;
  Object? billingError;
  void Function(Map<String, dynamic>)? afterSave;
  Completer<Map<String, dynamic>>? pendingSave;
  final billingValue = <String, dynamic>{
    'version': 7,
    'billingMode': 'METERED',
    'currency': 'CNY',
    'inputPerMillion': '1.0',
    'outputPerMillion': '2.0',
    'model': 'fixture-model',
  };
  @override
  Future<Map<String, dynamic>> read({
    int days = 30,
    int page = 0,
    int size = 20,
    String? userId,
    String? providerId,
  }) {
    reads.add({
      'days': days,
      'page': page,
      'size': size,
      'userId': userId,
      'providerId': providerId,
    });
    return pendingReads.isEmpty
        ? Future.value(data)
        : pendingReads.removeFirst();
  }

  @override
  Future<Map<String, dynamic>> billing(String providerId) async {
    if (billingError case final error?) throw error;
    return Map.of(billingValue);
  }

  @override
  Future<Map<String, dynamic>> saveBilling(
    String providerId,
    Map<String, dynamic> values,
  ) async {
    saved.add((providerId, Map.of(values)));
    if (saveError case final error?) throw error;
    if (pendingSave case final pending?) return pending.future;
    afterSave?.call(values);
    return {
      ...values,
      'version': (values['version'] as int) + 1,
      'model': 'fixture-model',
    };
  }
}

class _Providers implements AiProviderRepository {
  int version = 7, reads = 0;
  String name = '测试 AI 服务';
  final enabledVersions = <int?>[];
  final pending = Queue<Future<List<AiProviderConfig>>>();
  Object? listError, usageError;
  @override
  Future<List<AiProviderConfig>> list() async {
    reads++;
    if (listError case final error?) throw error;
    if (pending.isNotEmpty) return pending.removeFirst();
    return [
      AiProviderConfig.fromJson({
        'id': _providerId,
        'name': name,
        'version': version,
        'model': 'fixture-model',
        'enabled': true,
      }),
    ];
  }

  @override
  Future<AiPresetCatalog> presets() async => AiPresetCatalog.empty;
  @override
  Future<AiUsageSummary> usage({int days = 30}) async {
    if (usageError case final error?) throw error;
    return AiUsageSummary(days: days, providers: const []);
  }

  @override
  Future<void> setEnabled(
    String id, {
    required bool enabled,
    int? version,
  }) async => enabledVersions.add(version);
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected provider operation ${invocation.memberName}',
  );
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? path;
  Map<String, dynamic>? query;
  Object? body;
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    this.path = path;
    this.query = query;
    return {};
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    this.path = path;
    this.body = body;
    return {};
  }
}
