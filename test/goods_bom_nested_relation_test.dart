import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/goods_bom_item.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_bom_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_bom_tab.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

class _FakeGoodsBomRepository implements GoodsBomRepository {
  _FakeGoodsBomRepository({this.empty = false});

  final bool empty;
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
  String? auditedParentId;
  String? auditedItemId;
  bool? auditedValue;

  @override
  Future<List<GoodsBomItem>> list(String goodsId) async {
    listCalls.add(goodsId);
    if (empty) return const [];
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

  @override
  Future<GoodsBomItem> setAudited(
    String goodsId,
    String itemId,
    bool audited,
  ) async {
    auditedParentId = goodsId;
    auditedItemId = itemId;
    auditedValue = audited;
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
        home: Scaffold(
          body: GoodsBomTab(
            goodsId: 'goods-a',
            canCreate: true,
            canEdit: true,
            canDelete: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final parentToggle = find.byKey(
    const ValueKey('goods-bom-tree-toggle-row-b'),
  );
  await tester.ensureVisible(parentToggle);
  // 层级列的明确箭头负责展开；整行单击只负责选择。
  expect(tester.getSize(parentToggle), const Size(48, 48));
  await tester.tap(parentToggle);
  await tester.pumpAndSettle();
  expect(repo.listCalls, contains('goods-b'));
  final nestedName = find.textContaining('Nested component');
  expect(nestedName, findsOneWidget);
  expect(find.text('1.1'), findsOneWidget);
  expect(find.text('组件 2 级'), findsOneWidget);
  expect(find.textContaining('路径：组件树 1.1'), findsOneWidget);
  // 单击嵌套行：选中（onSelectionChanged 驱动 _selected），编辑/删除按钮随之可用。
  await tester.tap(nestedName);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'goods:view + goods:bom:create shows the primary add button and opens flow',
    (tester) async {
      final repo = _FakeGoodsBomRepository(empty: true);
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            goodsBomRepositoryProvider.overrideWithValue(repo),
            currentPermissionsProvider.overrideWithValue({
              Perm.goodsView,
              Perm.goodsBomCreate,
            }),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: const MaterialApp(
            home: Scaffold(
              body: GoodsBomTab(
                goodsId: 'goods-a',
                canCreate: true,
                canEdit: false,
                canDelete: false,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final add = find.byKey(const Key('goods-bom-add-component'));
      expect(add, findsOneWidget);
      expect(find.text('暂无组装信息，点上方「添加组件」录入'), findsOneWidget);
      expect(find.text('编辑'), findsNothing);
      expect(find.text('删除'), findsNothing);

      await tester.tap(add);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('添加位置'), findsOneWidget);
      expect(find.text('选择组件'), findsOneWidget);
    },
  );

  testWidgets('nested delete uses the owning parent goods id', (tester) async {
    final repo = _FakeGoodsBomRepository();
    await _pumpBom(tester, repo);

    await tester.tap(find.text('删除').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(repo.deletedParentId, 'goods-b');
    expect(repo.deletedItemId, 'row-c');
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '删除'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<UtenButton>(find.widgetWithText(UtenButton, '编辑'))
          .onPressed,
      isNull,
    );
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
    // A legacy-only history row stays untouched; ordinary editing must not turn
    // its old integer shadow into a new runtime relationship.
    expect(repo.updatedBody?.containsKey('colorLegacyId'), isFalse);
    expect(repo.updatedBody?.containsKey('colorId'), isFalse);
    expect(repo.updatedBody?['qty'], 3);
    // 生产管控字段已从编辑器移除（服务端 apply() 在省略时保留既有值），
    // 故保存体不再包含 controlStage/consumptionBasis 等。
    expect(repo.updatedBody?.containsKey('controlStage'), isFalse);
    expect(repo.updatedBody?.containsKey('hardGate'), isFalse);
  });

  testWidgets('audit mode marks row audited on single tap', (tester) async {
    final repo = _FakeGoodsBomRepository();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsBomRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue({Perm.goodsBomAudit}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        // canEdit=false：审计与编辑权限解耦（质检可只有审计权）。
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: false,
              canEdit: false,
              canDelete: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('审计模式'));
    await tester.pumpAndSettle();
    expect(find.text('退出审计'), findsOneWidget);

    // 单击行即翻面审计标记（不必双击）。
    final parentRow = find
        .ancestor(
          of: find.text('Parent component'),
          matching: find.byType(InkWell),
        )
        .first;
    await tester.ensureVisible(parentRow);
    await tester.tap(parentRow);
    await tester.pumpAndSettle();

    expect(repo.auditedParentId, 'goods-a');
    expect(repo.auditedItemId, 'row-b');
    expect(repo.auditedValue, isTrue);
  });

  testWidgets('audit mode button hidden without goods:bom:audit', (
    tester,
  ) async {
    final repo = _FakeGoodsBomRepository();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          goodsBomRepositoryProvider.overrideWithValue(repo),
          currentPermissionsProvider.overrideWithValue(const {}),
          isSuperAdminProvider.overrideWithValue(false),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: GoodsBomTab(
              goodsId: 'goods-a',
              canCreate: false,
              canEdit: false,
              canDelete: false,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('审计模式'), findsNothing);
    expect(find.byKey(const Key('goods-bom-add-component')), findsNothing);
  });

  test('BOM 详情解析 UUID 真源颜色和默认供应商', () {
    final item = GoodsBomItem.fromJson({
      'id': 'line-1',
      'componentGoodsId': 'goods-1',
      'colorId': 'color-uuid',
      'colorLegacyId': 7,
      'defaultSupplierId': 'supplier-uuid',
      'vendLegacyId': 9,
    });

    expect(item.colorId, 'color-uuid');
    expect(item.defaultSupplierId, 'supplier-uuid');
  });
}
