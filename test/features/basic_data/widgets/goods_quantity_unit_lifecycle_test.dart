import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/features/basic_data/models/goods_node.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/basic_data/repositories/goods_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/goods_detail_body.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  for (final unresolved in [false, true]) {
    testWidgets('已使用货品保留${unresolved ? '未核对历史' : '原'}单位并可保存其它资料', (
      tester,
    ) async {
      final repository = _GoodsRepository(
        _detail(locked: true, unresolved: unresolved),
      );
      await _pump(tester, repository);
      final locked = find.byKey(const ValueKey('goods-quantity-unit-locked'));
      expect(locked, findsOneWidget);
      expect(_unitPicker(), findsNothing);
      expect(
        find.descendant(
          of: locked,
          matching: find.text(unresolved ? '旧单位12' : '个'),
        ),
        findsOneWidget,
      );
      await Scrollable.ensureVisible(tester.element(locked), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: locked, matching: find.byType(UtenFieldHintIcon)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(unresolved ? '不能在这里猜选单位' : '基本单位不能再改'),
        findsWidgets,
      );
      await tester.tap(find.text('保存').hitTestable());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(repository.body, isNotNull);
      expect(repository.body!.containsKey('unitId'), isFalse);
      expect(repository.body!.containsKey('unitLegacyId'), isFalse);
      expect(repository.body!['name'], '数量基准货品');
      expect(repository.detailValue.unitLegacyId, 12);
    });
  }

  testWidgets('未使用货品可通过原单位选择器改单位，提示固定时点', (tester) async {
    final repository = _GoodsRepository(_detail(locked: false));
    await _pump(tester, repository);
    final picker = _unitPicker();
    expect(picker, findsOneWidget);
    expect(tester.widget<UtenDropdownField>(picker).info, contains('开始使用后会固定'));
    await Scrollable.ensureVisible(tester.element(picker), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: picker, matching: find.text('个')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('箱').last);
    await tester.pumpAndSettle();
    expect(tester.widget<UtenDropdownField>(picker).value, 'unit-box');
    await tester.tap(find.text('保存').hitTestable());
    await tester.pumpAndSettle();
    expect(repository.body?['unitId'], 'unit-box');
    expect(tester.takeException(), isNull);
  });
}

GoodsDetail _detail({
  required bool locked,
  bool unresolved = false,
}) => GoodsDetail.fromJson({
  'id': 'goods-1',
  'name': '数量基准货品',
  'code': 'HP000001',
  'categoryId': 'category-1',
  'sourceType': '采购',
  'status': '使用',
  // These unit-lifecycle cases use a permitted editor of this exact goods object.
  // The current detail API supplies object scope independently of button permissions.
  'writable': true,
  'unitId': unresolved ? null : 'unit-piece',
  'unitName': unresolved ? '旧单位12' : '个',
  'unitLegacyId': 12,
  'quantityUnitLocked': locked,
});

Finder _unitPicker() => find.byWidgetPredicate(
  (widget) => widget is UtenDropdownField && widget.label == '基本单位',
);

Future<void> _pump(WidgetTester tester, _GoodsRepository repository) async {
  await tester.binding.setSurfaceSize(const Size(1200, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentPermissionsProvider.overrideWithValue(const {
          Perm.goodsEdit,
          Perm.goodsStatus,
        }),
        isSuperAdminProvider.overrideWithValue(false),
        goodsRepositoryProvider.overrideWithValue(repository),
        colorDictProvider.overrideWith((ref) async => const []),
        unitDictProvider.overrideWith(
          (ref) async => const [
            UnitListItem(id: 'unit-piece', name: '个'),
            UnitListItem(id: 'unit-box', name: '箱'),
          ],
        ),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: GoodsDetailBody(
            initialDetail: repository.detailValue,
            initialCategoryId: 'category-1',
            initialTab: 0,
            canCreate: false,
            canEdit: true,
            canStatus: true,
            canBomCreate: false,
            canBomEdit: false,
            canBomDelete: false,
            onToggleStatus: null,
            onDelete: null,
            onViewMovements: null,
            onDataChanged: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('编辑'));
  await tester.pumpAndSettle();
}

class _GoodsRepository implements GoodsRepository {
  _GoodsRepository(this.detailValue);
  final GoodsDetail detailValue;
  Map<String, dynamic>? body;
  @override
  Future<GoodsDetail> detail(String id) async => detailValue;
  @override
  Future<void> update(String id, Map<String, dynamic> body) async {
    this.body = body;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
