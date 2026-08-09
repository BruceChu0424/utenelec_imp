import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
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
    expect(repo.updatedBody?['controlStage'], 'FINISH');
    expect(repo.updatedBody?['consumptionBasis'], 'PER_PACKAGE');
    expect(repo.updatedBody?['basisOutputQty'], 100);
    expect(repo.updatedBody?['allowPartialPackage'], isFalse);
    expect(repo.updatedBody?['hardGate'], isFalse);
  });

  testWidgets('shipping reference clears and disables the hard gate', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(find.text('编辑').first);
    await tester.pumpAndSettle();
    final hardGateTile = find.ancestor(
      of: find.text('缺料作为硬门槛'),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(hardGateTile);
    await tester.tap(hardGateTile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(hardGateTile).value, isTrue);

    final stageField = find.byWidgetPredicate(
      (widget) =>
          widget is UtenDropdownField && widget.label == '什么时候需要',
    );
    await tester.ensureVisible(stageField);
    await tester.tap(stageField);
    await tester.pumpAndSettle();
    await tester.tap(find.text('发货参考').last);
    await tester.pumpAndSettle();

    final disabledHardGate = tester.widget<SwitchListTile>(hardGateTile);
    expect(disabledHardGate.value, isFalse);
    expect(disabledHardGate.onChanged, isNull);
    expect(find.text('发货参考/仅参考只能提醒，不能设为生产硬门槛'), findsOneWidget);
    expect(find.textContaining('不预留包材、不阻止实际发货'), findsOneWidget);

    await tester.ensureVisible(find.text('保存'));
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(repo.updatedBody?['controlStage'], 'SHIP');
    expect(repo.updatedBody?['hardGate'], isFalse);
  });
}
