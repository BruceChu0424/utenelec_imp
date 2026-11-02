import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_access_policy.dart';
import 'package:uten_imp/shared/auth/commercial_price_visibility.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/pricing/price_analysis_access.dart';

void main() {
  final fixture =
      jsonDecode(
            File('contracts/price-analysis-access/v1.json').readAsStringSync(),
          )
          as Map;
  for (final raw in fixture['cases'] as List) {
    final row = Map<String, dynamic>.from(raw as Map);
    test('shared price capabilities: ${row['name']}', () {
      final grants = Set<String>.from(row['permissions'] as List);
      final admin = row['superAdmin'] == true;
      final analyze = [
        for (final kind in priceAnalysisKinds)
          if (canAnalyzePriceKind(grants, admin, kind)) kind,
      ];
      expect(analyze, row['analyze']);
      expect(readablePriceHistoryKinds(grants, admin), row['history']);
      final allowed = (row['history'] as List).isNotEmpty;
      final user = AppUser(
        id: 'reader',
        code: 'reader',
        name: 'Reader',
        permissions: grants.toList(),
        superAdmin: admin,
      );
      const route = '/basicinfo/goods/id/price-analysis';
      expect(locationAllowedFor(grants, admin, route), allowed);
      expect(employeePermissionRedirect(user, route) == null, allowed);
    });
  }
  test(
    'commercial amounts require the exact price code, not scope/edit/analysis',
    () {
      for (final pool in [
        'purchase_order',
        'purchase_receipt',
        'purchase_return',
        'purchase_report',
        'subcontract_order',
        'subcontract_receipt',
        'subcontract_return',
        'subcontract_report',
      ]) {
        expect(
          canViewCommercialPrice({
            'finance:view:all',
            '$pool:view',
            '$pool:edit',
            'goods:price_analysis:view',
          }, '$pool:price:view'),
          isFalse,
        );
        expect(
          canViewCommercialPrice({'$pool:price:view'}, '$pool:price:view'),
          isTrue,
        );
      }
      expect(canAnalyzePriceKind({}, true, 'UNKNOWN'), isFalse);
      expect(canViewCommercialPrice({'finance:view:all'}, null), isFalse);
    },
  );
}
