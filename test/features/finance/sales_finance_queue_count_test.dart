import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/finance/providers/sales_order_finance_confirmation_count_provider.dart';
import 'package:uten_imp/shared/badges/badge_registry.dart';
import '../../helpers/badge_summary_fixture.dart';

void main() {
  test(
    'pending category follows the same authoritative summary as its parent and refreshes with it',
    () {
      final container = ProviderContainer(
        overrides: [
          fixedBadgeSummaryOverride(
            badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 7}),
          ),
        ],
      );
      addTearDown(container.dispose);
      expect(container.read(salesOrderFinancePendingCountProvider), 7);
      final notifier =
          container.read(badgeSummaryProvider.notifier)
              as FixedBadgeSummaryNotifier;
      notifier.emit(
        badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 3}),
      );
      expect(container.read(salesOrderFinancePendingCountProvider), 3);
      notifier.emit(
        badgeSummaryFixture(facts: {BadgeFact.salesOrderFinance: 0}),
      );
      expect(container.read(salesOrderFinancePendingCountProvider), 0);
    },
  );
  test(
    'unknown or ungranted summary stays unknown rather than inventing zero',
    () {
      final container = ProviderContainer(
        overrides: [fixedBadgeSummaryOverride()],
      );
      addTearDown(container.dispose);
      expect(container.read(salesOrderFinancePendingCountProvider), isNull);
    },
  );
}
