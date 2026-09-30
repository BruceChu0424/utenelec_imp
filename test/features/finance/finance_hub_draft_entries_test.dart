// 钱流入口统一为右上角草稿按钮，数量包含业务草稿与资料草稿且不重复。
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
import 'package:uten_imp/shared/drafts/form_drafts_page.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/core/router/route_names.dart';
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
              GoRoute(
                path: RouteName.formDrafts,
                builder: (_, state) => Scaffold(
                  body: Text('drafts:${state.pathParameters['categoryId']}'),
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

  testWidgets('右上角草稿红数合并业务与资料草稿，不再显示分类胶囊', (tester) async {
    await pumpHub(
      tester,
      drafts: [
        _draft(
          'r-1',
          BadgeModule.finance,
          'financeReceipt',
          '/finance/receipts/new',
        ),
        _draft('currency-1', BadgeModule.finance, null, '/basicinfo/currency'),
      ],
      facts: {'drafts.financeReceipt': 2},
    );
    final button = find.byKey(const ValueKey('form-drafts-button-finance'));
    expect(button, findsOneWidget);
    expect(
      find.descendant(of: find.byType(UtenAppBar), matching: button),
      findsOneWidget,
    );
    // 两张服务端单据 + 一份本机收款 + 一份资料草稿。
    expect(
      find.descendant(of: button, matching: find.text('4')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('finance-hub-categories')), findsNothing);
    expect(find.text('资料草稿'), findsNothing);
    expect(find.text('业务入口'), findsNothing);
  });

  testWidgets('草稿按钮进入钱流统一草稿页', (tester) async {
    await pumpHub(tester);
    await tester.tap(find.byKey(const ValueKey('form-drafts-button-finance')));
    await tester.pumpAndSettle();
    expect(find.text('drafts:finance'), findsOneWidget);
  });

  testWidgets('已创建业务单据的恢复检查点不重复计数，资产草稿保留原工作台归属', (tester) async {
    await pumpHub(
      tester,
      drafts: [
        _draft(
          'r-1',
          BadgeModule.finance,
          'financeReceipt',
          '/finance/receipts/new',
          data: {'createdDocId': 'receipt-created'},
        ),
        _draft(
          'asset-1',
          BadgeModule.finance,
          null,
          '/finance/assets/new?ledger=fixedAsset',
        ),
        _draft(
          'policy-1',
          BadgeModule.finance,
          null,
          '/finance/assets?draftForm=assetPolicy',
        ),
        _draft('currency-1', BadgeModule.finance, null, '/basicinfo/currency'),
      ],
      facts: {'drafts.financeReceipt': 2},
    );
    final button = find.byKey(const ValueKey('form-drafts-button-finance'));
    expect(
      find.descendant(of: button, matching: find.text('3')),
      findsOneWidget,
    );
    final scope = formDraftsPageCategories['finance']!.scope;
    expect(
      scope.matches(
        _draft('asset', BadgeModule.finance, null, '/finance/assets/new'),
      ),
      isFalse,
    );
    expect(
      scope.matches(
        _draft('currency', BadgeModule.finance, null, '/basicinfo/currency'),
      ),
      isTrue,
    );
  });

  testWidgets('草稿为零时保留入口，不显示红色零数字', (tester) async {
    await pumpHub(
      tester,
      superAdmin: false,
      permissions: const {Perm.financePaymentView},
    );
    final button = find.byKey(const ValueKey('form-drafts-button-finance'));
    expect(
      find.descendant(of: button, matching: find.text('草稿')),
      findsOneWidget,
    );
    expect(find.descendant(of: button, matching: find.text('0')), findsNothing);
  });
}
