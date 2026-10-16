import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/stock/models/instant_inventory_scope.dart';

void main() {
  for (final browse in [null, 'raw']) {
    for (final searchCategory in [null, 'finished']) {
      test(
        'navigation roundtrip keeps browse=$browse and search=$searchCategory separate',
        () {
          final scope = InstantInventoryScope(
            categoryId: searchCategory,
            keyword: '螺丝 M3 & 4*50',
            includeRelated: true,
            warehouseId: 'warehouse-main',
            includeDefective: true,
            includeLineSide: true,
            owningWarehouseNull: true,
            colorId: 'red',
            series: 'GD',
            unitId: 'unit-1',
          );
          final navigation = InstantInventoryNavigationContext(
            scope: scope,
            browseCategoryId: browse,
            returnTo: '/workbench?department=production&keyword=端子 M3',
          );
          final uri = Uri(
            path: '/inventory',
            queryParameters: navigation.toQuery(),
          );
          final restored = InstantInventoryNavigationContext.fromQuery(
            Uri.parse(uri.toString()).queryParameters,
          );
          expect(restored.scope, scope);
          expect(restored.browseCategoryId, browse);
          expect(restored.returnTo, navigation.returnTo);
          expect(restored.toQuery()['browseCategoryId'], browse ?? '');
          expect(scope.toQuery(), isNot(contains('browseCategoryId')));
          expect(scope.toQuery(), isNot(contains('returnTo')));
          expect(
            scope.toQueryParameters(),
            isNot(contains('browseCategoryId')),
          );
          expect(scope.toQueryParameters(), isNot(contains('returnTo')));
        },
      );
    }
  }

  test(
    'legacy keyword URL and constructor keep category as browse point and search global',
    () {
      const oldScope = InstantInventoryScope(
        categoryId: 'raw',
        keyword: '螺丝',
        includeRelated: true,
        inventoryOnly: false,
        includeLineSide: true,
        warehouseId: 'warehouse-main',
        owningWarehouseNull: true,
        colorNull: true,
        series: 'GD',
        unitId: 'unit-1',
      );
      final constructor = InstantInventoryNavigationContext.fromLegacyScope(
        oldScope,
      );
      final fromUrl = InstantInventoryNavigationContext.fromQuery({
        ...oldScope.toQuery(),
        'returnTo': '/workbench?department=production',
      });
      for (final navigation in [constructor, fromUrl]) {
        expect(navigation.scope.categoryId, isNull);
        expect(navigation.browseCategoryId, 'raw');
        expect(
          navigation.scope.toQuery(),
          {...oldScope.toQuery()}..remove('categoryId'),
        );
        expect(navigation.toQuery()['browseCategoryId'], 'raw');
        expect(
          InstantInventoryNavigationContext.fromQuery(
            navigation.toQuery(),
          ).scope,
          navigation.scope,
        );
      }
      expect(fromUrl.returnTo, '/workbench?department=production');
    },
  );

  test(
    'without keyword the actual business category overrides stale navigation metadata',
    () {
      for (final browse in ['', 'finished']) {
        final navigation = InstantInventoryNavigationContext.fromQuery({
          'categoryId': 'raw',
          'browseCategoryId': browse,
        });
        expect(navigation.scope.categoryId, 'raw');
        expect(navigation.browseCategoryId, 'raw');
      }
      final all = InstantInventoryNavigationContext.fromQuery({
        'browseCategoryId': 'raw',
      });
      expect(all.scope.categoryId, isNull);
      expect(all.browseCategoryId, isNull);
    },
  );
}
