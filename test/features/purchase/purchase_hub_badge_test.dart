// 采购 hub 卡红数口径：任务中心卡 = purchaseTaskCenter + purchaseDrafts
// (服务端) + 本地采购草稿(effective 按 ID 去重并入)，与顶栏模块红数同源。
// 这里刻意不声明 formDraftModule——purchaseDrafts 入口已含本地草稿，
// 再加 formDraftModule 会把本地数算两遍(卡红数超过顶栏模块红数)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
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

FormDraft _draft(String id, BadgeModule module, String? kind, String route) =>
    FormDraft(
      id: id,
      title: '草稿 $id',
      module: module,
      draftKind: kind,
      route: route,
      permission: '',
      updatedAt: DateTime.now(),
      data: const {},
    );

void main() {
  late SharedPreferences preferences;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  Future<void> pumpPage(WidgetTester tester, List<FormDraft> drafts) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(true),
          authenticatedScopeProvider.overrideWithValue(null),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: const {
                BadgeEntry.purchaseTaskCenter: (3, 4),
                BadgeEntry.purchaseDrafts: (2, 0),
              },
            ),
          ),
          formDraftsProvider.overrideWith(() => _FixedFormDrafts(drafts)),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: PurchaseHubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  Finder taskCard() => find.byWidgetPredicate(
    (widget) => widget is UtenHubCard && widget.label == '采购任务中心',
  );

  testWidgets('任务中心卡红数含本地采购草稿，与顶栏模块红数一致', (tester) async {
    await pumpPage(tester, [
      _draft(
        'order-1',
        BadgeModule.purchase,
        'purchaseOrder',
        '/purchase/orders/new',
      ),
      _draft('sales-1', BadgeModule.sales, 'salesOrder', '/sales/orders/new'),
    ]);

    // 3(任务中心) + 2(服务端草稿) + 1(本地采购草稿) = 6；销售草稿不混入。
    final redBadge = find.descendant(
      of: taskCard(),
      matching: find.byType(UtenNotificationBadge),
    );
    expect(tester.widget<UtenNotificationBadge>(redBadge).count, 6);
    expect(
      tester
          .widget<UtenInProgressBadge>(
            find.descendant(
              of: taskCard(),
              matching: find.byType(UtenInProgressBadge),
            ),
          )
          .count,
      4,
    );
    expect(find.text('待办 6'), findsOneWidget);
  });
}
