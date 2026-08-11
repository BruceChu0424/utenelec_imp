import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';

class _FakeGoodsBomRepository implements GoodsBomRepository {
  final listCalls = <String>[];
  final parent = const GoodsBomItem(
    id: 'row-b',
    componentGoodsId: 'goods-b',
    componentCode: 'B',
    componentName: 'Parent component',
    hasChildren: true,
    qty: 1,
  );

  final nested = const GoodsBomItem(
    id: 'row-c',
    componentGoodsId: 'goods-c',
    componentCode: 'C',
    componentName: 'Nested component',
    colorLegacyId: 9,
    qty: 2,
    price: 12,
    controlStage: BomControlStage.finish,
    consumptionBasis: BomConsumptionBasis.perPackage,
    basisOutputQty: 100,
    allowPartialPackage: false,
    hardGate: false,
  );

  String? deletedParentId;
  String? deletedItemId;
  String? updatedParentId;
  String? updatedItemId;
  Map<String, dynamic>? updatedBody;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    return switch (goodsId) {
      'goods-a' => [parent],
      'goods-b' => [nested],
      _ => const [],
    };
  }

  @override
  Future<GoodsBomItem> create(
    String goodsId,
    Map<String, dynamic> body,
  ) async => nested;

  @override
  Future<void> delete(String goodsId, String itemId) async {
    deletedParentId = goodsId;
    deletedItemId = itemId;
  }

  @override
  Future<GoodsBomItem> update(
    String goodsId,
    String itemId,
    Map<String, dynamic> body,
  ) async {
    updatedParentId = goodsId;
    updatedItemId = itemId;
    updatedBody = Map<String, dynamic>.from(body);
    return nested;
  }
}

Future<void> _pumpBom(WidgetTester tester, _FakeGoodsBomRepository repo) async {
  await tester.binding.setSurfaceSize(const Size(1600, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [goodsBomRepositoryProvider.overrideWithValue(repo)],
      child: const MaterialApp(
        home: Scaffold(body: GoodsBomTab(goodsId: 'goods-a', canEdit: true)),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final parentRow = find
      .ancestor(
        of: find.text('Parent component'),
        matching: find.byType(InkWell),
      )
      .first;
  await tester.ensureVisible(parentRow);
  await tester.tap(parentRow);
  await tester.pumpAndSettle();
  expect(repo.listCalls, contains('goods-b'));
  final nestedName = find.textContaining('Nested component');
  expect(nestedName, findsOneWidget);
  await tester.tap(nestedName);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nested delete uses the owning parent goods id', (tester) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repo.deletedParentId, 'goods-b');
    expect(repo.deletedItemId, 'row-c');
  });

  testWidgets('nested edit keeps row color and uses the owning parent', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(find.text('编辑').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '3');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(repo.updatedParentId, 'goods-b');
    expect(repo.updatedItemId, 'row-c');
    expect(repo.updatedBody?['colorLegacyId'], 9);
    expect(repo.updatedBody?['qty'], 3);
    // 生产管控字段已从编辑器移除（服务端 apply() 在省略时保留既有值），
    // 故保存体不再包含 controlStage/consumptionBasis 等。
    expect(repo.updatedBody?.containsKey('controlStage'), isFalse);
    expect(repo.updatedBody?.containsKey('hardGate'), isFalse);
  });
}
