import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/cards/uten_hub_card.dart';
import 'package:uten_imp/components/feedback/uten_in_progress_badge.dart';
import 'package:uten_imp/components/feedback/uten_notification_badge.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/features/finance/pages/finance_hub_page.dart';
import 'package:uten_imp/features/production/pages/production_hub_page.dart';
import 'package:uten_imp/features/purchase/pages/purchase_hub_page.dart';
import 'package:uten_imp/features/quality/pages/quality_task_center_page.dart';
import 'package:uten_imp/features/sales/pages/sales_hub_page.dart';
import 'package:uten_imp/features/subcontract/pages/subcontract_hub_page.dart';
import 'package:uten_imp/features/warehouse/pages/warehouse_hub_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

import '../helpers/badge_summary_fixture.dart';

void main() {
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
  });

  final summary = badgeSummaryFixture(
    entries: const {
      BadgeEntry.salesAttention: (120, 0),
      BadgeEntry.salesOrderInFlight: (0, 140),
      BadgeEntry.purchaseTaskCenter: (120, 140),
      BadgeEntry.purchaseSupplierReturn: (125, 0),
      BadgeEntry.subcontractTaskCenter: (120, 140),
      BadgeEntry.subcontractSupplierReturn: (125, 0),
      BadgeEntry.productionSchedule: (120, 0),
      BadgeEntry.productionBatches: (0, 140),
      BadgeEntry.productionRateApprovals: (120, 0),
      BadgeEntry.productionMaterialIncrementApprovals: (125, 0),
      BadgeEntry.financeAuditCenter: (120, 0),
      BadgeEntry.expenseFinance: (125, 0),
      BadgeEntry.warehouseOutboundCenter: (120, 0),
      BadgeEntry.warehouseQualityResult: (125, 140),
      BadgeEntry.qualityIqcPending: (120, 0),
      BadgeEntry.qualityFqcPending: (125, 0),
    },
    facts: const {
      BadgeFact.productionScheduleCount: 120,
      BadgeFact.productionScheduleUrgent: 1,
      BadgeFact.productionScheduleOverdue: 120,
    },
  );

  const pages = [
    ('sales', SalesHubPage()),
    ('purchase', PurchaseHubPage()),
    ('subcontract', SubcontractHubPage()),
    ('production', ProductionHubPage()),
    ('finance', FinanceHubPage()),
    ('warehouse', WarehouseHubPage()),
    ('quality', QualityTaskCenterPage()),
  ];
  const sizes = [
    (width: 375.0, scale: 1.5),
    (width: 700.0, scale: 2.0),
    (width: 1280.0, scale: 1.0),
  ];

  for (final page in pages) {
    for (final dark in [false, true]) {
      for (final size in sizes) {
        testWidgets('${page.$1} ${dark ? 'dark' : 'light'} ${size.width}dp '
            '${size.scale}x keeps task counts inside their cards', (
          tester,
        ) async {
          final errors = <FlutterErrorDetails>[];
          final previousErrorHandler = FlutterError.onError;
          FlutterError.onError = (details) {
            errors.add(details);
            previousErrorHandler?.call(details);
          };
          addTearDown(() => FlutterError.onError = previousErrorHandler);
          tester.view.physicalSize = Size(size.width, 1200);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                sharedPreferencesProvider.overrideWithValue(preferences),
                currentPermissionsProvider.overrideWithValue(const {}),
                isSuperAdminProvider.overrideWithValue(true),
                fixedBadgeSummaryOverride(summary),
              ],
              child: MaterialApp(
                theme: dark ? buildDarkTheme() : buildLightTheme(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                locale: const Locale('zh'),
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(size.scale)),
                  child: child!,
                ),
                home: page.$2,
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            tester.takeException(),
            isNull,
            reason: errors.map((details) => details.toString()).join('\n'),
          );

          final cards = find.byType(UtenHubCard);
          expect(cards, findsWidgets);
          for (final card in cards.evaluate()) {
            final cardFinder = find.byWidget(card.widget);
            final rect = tester.getRect(cardFinder);
            for (final type in [UtenNotificationBadge, UtenInProgressBadge]) {
              final badges = find.descendant(
                of: cardFinder,
                matching: find.byType(type),
              );
              for (final badge in badges.evaluate()) {
                final badgeRect = tester.getRect(find.byWidget(badge.widget));
                if (badgeRect.isEmpty) continue;
                expect(badgeRect.left, greaterThanOrEqualTo(rect.left));
                expect(badgeRect.right, lessThanOrEqualTo(rect.right));
              }
            }
          }
        });
      }
    }
  }
}
