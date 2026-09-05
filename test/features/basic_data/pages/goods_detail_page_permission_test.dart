import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/pages/goods_detail_page.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

final _testPermissionsProvider =
    NotifierProvider<_TestPermissions, Set<String>>(_TestPermissions.new);

class _TestPermissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  void replace(Set<String> permissions) => state = permissions;
}

class _GoodsRepository extends Fake implements GoodsRepository {
  @override
  Future<GoodsDetail> detail(String id) async => const GoodsDetail(
    id: 'goods-1',
    code: 'P-001',
    name: '测试货品',
    status: '使用',
    sourceType: '自制',
  );
}

class _BomRepository extends Fake implements GoodsBomRepository {
  @override
  Future<List<GoodsBomItem>> list(String goodsId) async => const [];
}

void main() {
  testWidgets('readable goods page reacts to BOM create permission refresh', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final container = ProviderContainer(
      overrides: [
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(_testPermissionsProvider),
        ),
        isSuperAdminProvider.overrideWithValue(false),
        goodsRepositoryProvider.overrideWithValue(_GoodsRepository()),
        goodsBomRepositoryProvider.overrideWithValue(_BomRepository()),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: GoodsDetailPage(goodsId: 'goods-1', initialTab: 1),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(_testPermissionsProvider.notifier).replace({Perm.goodsView});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);

    container.read(_testPermissionsProvider.notifier).replace({
      Perm.goodsView,
      Perm.goodsBomCreate,
    });
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('goods-bom-add-component')), findsOneWidget);

    container.read(_testPermissionsProvider.notifier).replace({Perm.goodsView});
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
  });
}
