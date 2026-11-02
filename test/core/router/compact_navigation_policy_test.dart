import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/compact_navigation_policy.dart';

void main() {
  test('workbench and management entries retain navigation', () {
    for (final path in [
      '/dashboard',
      '/notice',
      '/profile',
      '/settings',
      '/sales',
      '/purchase',
      '/warehouse',
      '/finance',
      '/production',
      '/basicinfo?returnTo=/dashboard',
      '/company-files',
      '/admin/permissions',
      '/payroll/slip',
    ]) {
      expect(
        UtenCompactNavigationPolicy.showsNavigation(path),
        isTrue,
        reason: path,
      );
    }
  });
  test('lists, detail pages and editors below an entry hide navigation', () {
    for (final path in [
      '/sales/quotes',
      '/sales/quotes/new',
      '/sales/orders/abc',
      '/basicinfo/unit',
      '/basicinfo/goods/abc',
      '/finance/receipts/new',
      '/settings/software-publish',
      '/notice/publish',
      '/payroll/slip/abc',
    ]) {
      expect(
        UtenCompactNavigationPolicy.showsNavigation(path),
        isFalse,
        reason: path,
      );
    }
  });
}
