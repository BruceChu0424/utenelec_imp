// 财务 hub「资料草稿」面板的钱流草稿下钻入口：
//  · 5 类单据各一枚（收款/付款/费用/收入/存取款），按 *:view 权限或计数>0 显示；
//  · 计数与 UtenDraftsButton 同源（draftCountsProvider = 服务端事实 + 本地草稿）；
//  · 点击深链 /finance/:seg?status=draft 预选列表草稿段；
//  · 资产草稿不放本面板——落点在资产工作台（政策草稿 Tab + 台账草稿筛选），
//    这里断言资料草稿表不含资产路由的本地草稿，保住「资料/业务」分区语义。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import '../../helpers/badge_summary_fixture.dart';

class _FixedFormDrafts extends FormDraftsNotifier {
  _FixedFormDrafts(this.initial);
  final List<FormDraft> initial;
  @override
  List<FormDraft> build() => initial;
}

FormDraft _draft(
  String id,
  BadgeModule module,
  String? kind,
  String route, {
  Map<String, dynamic> data = const {},
}) => FormDraft(
  id: id,
  title: '草稿 $id',
  module: module,
  draftKind: kind,
  route: route,
  permission: '',
  updatedAt: DateTime.now(),
  data: data,
);

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Future<void> pumpHub(
    WidgetTester tester, {
    List<FormDraft> drafts = const [],
    Set<String> permissions = const {},
    bool superAdmin = true,
    Map<String, int> facts = const {},
  }) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(permissions),
          isSuperAdminProvider.overrideWithValue(superAdmin),
          authenticatedScopeProvider.overrideWithValue(null),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: const {BadgeEntry.financeDrafts: (2, 0)},
              facts: facts,
            ),
          ),
          formDraftsProvider.overrideWith(() => _FixedFormDrafts(drafts)),
        ],
        child: MaterialApp.router(
          routerConfig: GoRouter(
            routes: [
              GoRoute(path: '/', builder: (_, _) => const FinanceHubPage()),
              // 深链落点桩：只回显 seg 与 status，验证 /finance/:seg?status=draft。
              GoRoute(
                path: '/finance/:seg',
                builder: (_, state) => Scaffold(
                  body: Text(
                    'list:${state.pathParameters['seg']}:'
                    '${state.uri.queryParameters['status']}',
                  ),
                ),
              ),
            ],
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Future<void> openDraftsPanel(WidgetTester tester) async {
    await tester.tap(find.text('资料草稿'));
    await tester.pumpAndSettle();
  }

  testWidgets('资料草稿面板显示 5 类钱流草稿入口，计数走 draftCounts 口径', (tester) async {
    // 服务端 2 张收款草稿 + 本地 1 张收款草稿（facts + local 同一来源合成 3）。
    await pumpHub(
      tester,
      drafts: [
        _draft(
          'r-1',
          BadgeModule.finance,
          'financeReceipt',
          '/finance/receipts/new',
        ),
      ],
      facts: {'drafts.financeReceipt': 2},
    );
    await openDraftsPanel(tester);

    expect(find.text('钱流草稿'), findsOneWidget);
    for (final label in ['收款草稿', '付款草稿', '费用草稿', '收入草稿', '存取款草稿']) {
      expect(find.text(label), findsOneWidget, reason: '$label 入口应显示');
    }
    // 收款草稿 = 服务端 2 + 本地 1；其余类计数为 0 不带红徽。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('finance-hub-money-draft-receipts')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
    // 钱流单据草稿不进「资料草稿」表本身（有自己的下钻入口）。
    expect(find.text('草稿 r-1'), findsNothing);
  });

  testWidgets('点击入口深链到对应列表并预选草稿段', (tester) async {
    await pumpHub(tester);
    await openDraftsPanel(tester);

    await tester.tap(
      find.byKey(const ValueKey('finance-hub-money-draft-bank-transfers')),
    );
    await tester.pumpAndSettle();

    expect(find.text('list:bank-transfers:draft'), findsOneWidget);
  });

  testWidgets('无权限且无计数时按类隐藏，有权限即显示', (tester) async {
    await pumpHub(
      tester,
      superAdmin: false,
      permissions: const {Perm.financePaymentView},
    );
    await openDraftsPanel(tester);

    expect(find.text('付款草稿'), findsOneWidget);
    expect(find.text('收款草稿'), findsNothing);
    expect(find.text('存取款草稿'), findsNothing);
  });

  testWidgets('资产路由草稿不混入资料草稿面板的本地草稿表', (tester) async {
    await pumpHub(
      tester,
      drafts: [
        _draft(
          'asset-1',
          BadgeModule.finance,
          null,
          '/finance/assets/new?ledger=fixedAsset',
        ),
        _draft('currency-1', BadgeModule.finance, null, '/basicinfo/currency'),
      ],
    );
    await openDraftsPanel(tester);

    // 资料草稿表只装资料类草稿；资产草稿去资产工作台（hub「资产」卡）。
    expect(find.text('草稿 currency-1'), findsOneWidget);
    expect(find.text('草稿 asset-1'), findsNothing);
  });
}
