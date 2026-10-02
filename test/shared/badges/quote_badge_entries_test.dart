// 报价核价徽章入口(ADR-134)：财务「报价待核价」、销售「报价被退回」「报价已核价待转订货」
// 三个入口的归属容器，以及钱流 hub「报价核价」卡挂的是哪个入口。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/badges/badge_scope.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../../helpers/badge_summary_fixture.dart';

void main() {
  test('quote entries live in the finance and sales containers', () {
    expect(BadgeEntry.financeQuoteReview.module, BadgeModule.finance);
    expect(BadgeEntry.salesQuoteFinanceRejected.module, BadgeModule.sales);
    expect(BadgeEntry.salesQuoteAwaitingConversion.module, BadgeModule.sales);
    expect(
      BadgeEntry.salesQuoteAwaitingCustomerConfirmation.module,
      BadgeModule.sales,
    );
  });

  test('summary parses the new entries and rolls them into containers', () {
    final summary = BadgeSummary.fromJson(const {
      'entries': {
        'financeQuoteReview': {'todo': 4, 'inProgress': 0},
        'salesQuoteFinanceRejected': {'todo': 1, 'inProgress': 0},
        'salesQuoteAwaitingConversion': {'todo': 2, 'inProgress': 0},
        'salesQuoteAwaitingCustomerConfirmation': {'todo': 3, 'inProgress': 0},
      },
      'modules': {
        'finance': {'todo': 4, 'inProgress': 0},
        'sales': {'todo': 6, 'inProgress': 0},
      },
      'total': {'todo': 10, 'inProgress': 0},
      'facts': {'financeRejected.salesQuote': 1},
    });
    expect(summary.entryTodo(BadgeEntry.financeQuoteReview), 4);
    expect(summary.entryTodo(BadgeEntry.salesQuoteFinanceRejected), 1);
    expect(summary.entryTodo(BadgeEntry.salesQuoteAwaitingConversion), 2);
    expect(
      summary.entryTodo(BadgeEntry.salesQuoteAwaitingCustomerConfirmation),
      3,
    );
    expect(summary.moduleTodo(BadgeModule.sales), 6);
    expect(summary.fact(BadgeFact.financeRejected('salesQuote')), 1);
  });

  testWidgets('finance hub shows the quote pricing card with its own entry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          currentPermissionsProvider.overrideWithValue(const {
            Perm.salesQuoteFinanceView,
          }),
          isSuperAdminProvider.overrideWithValue(false),
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(
              entries: {BadgeEntry.financeQuoteReview: (4, 0)},
            ),
          ),
        ],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: Locale('zh'),
          home: FinanceHubPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final card = tester.widget<UtenHubCard>(
      find.byWidgetPredicate((w) => w is UtenHubCard && w.label == '报价核价'),
    );
    expect(
      card.badgeScope,
      const BadgeScope.entry(BadgeEntry.financeQuoteReview),
    );
    // 只持报价核价查看码：业务审核中心卡不出现。
    expect(
      find.byWidgetPredicate((w) => w is UtenHubCard && w.label == '业务审核中心'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}
