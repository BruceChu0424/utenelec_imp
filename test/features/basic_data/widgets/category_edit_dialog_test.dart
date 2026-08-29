import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/category_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';

void main() {
  testWidgets('编辑分类时节点选择先暂存，取消不改变且确定后才提交新上级', (tester) async {
    CategoryEditResult? submitted;

    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      editing: const ProductCategoryDetail(
        id: 'current-category',
        code: 'CAT-CURRENT',
        name: '当前分类',
        level: 1,
        parentId: 'original-parent',
        parentName: '原上级分类',
        path: '原上级分类 > 当前分类',
        childCount: 0,
      ),
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();

    await tester.tap(find.text('目标上级分类(CAT-TARGET)'));
    await tester.pump();

    expect(find.text('选择上级分类'), findsOneWidget);
    expect(
      tester
          .widget<UtenCategoryTreeView<ProductCategoryNode>>(
            find.byType(UtenCategoryTreeView<ProductCategoryNode>),
          )
          .selectedIds,
      {'target-parent'},
    );

    await tester.tap(_pickerSheetAction('取消'));
    await tester.pumpAndSettle();

    expect(find.text('原上级分类'), findsOneWidget);
    expect(find.text('目标上级分类'), findsNothing);

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();
    await tester.tap(find.text('目标上级分类(CAT-TARGET)'));
    await tester.pump();
    await tester.tap(_pickerSheetAction('确定'));
    await tester.pumpAndSettle();

    expect(find.text('目标上级分类'), findsOneWidget);

    await tester.enterText(_textFieldWithLabel('名称'), '修改后分类');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.parentId, 'target-parent');
    expect(submitted!.name, '修改后分类');
  });

  testWidgets('编辑分类未改变上级时只提交名称', (tester) async {
    CategoryEditResult? submitted;

    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      editing: const ProductCategoryDetail(
        id: 'current-category',
        code: 'CAT-CURRENT',
        name: '当前分类',
        level: 1,
        parentId: 'original-parent',
        parentName: '原上级分类',
        path: '原上级分类 > 当前分类',
        childCount: 0,
      ),
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );

    await tester.enterText(_textFieldWithLabel('名称'), '只改名称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(submitted, isNotNull);
    expect(submitted!.name, '只改名称');
    expect(submitted!.parentId, isNull);
  });

  testWidgets('紧凑屏分类位置使用底部滑窗且确认操作可见并回填', (tester) async {
    await _pumpCategoryDialog(
      tester,
      surfaceSize: const Size(375, 812),
      tree: _categoryTree(),
      editing: const ProductCategoryDetail(
        id: 'current-category',
        code: 'CAT-CURRENT',
        name: '当前分类',
        level: 1,
        parentId: 'original-parent',
        parentName: '原上级分类',
        path: '原上级分类 > 当前分类',
        childCount: 0,
      ),
      onSubmit: (_) async => true,
    );

    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(UtenLocationField));
    await tester.pumpAndSettle();

    expect(find.text('选择上级分类'), findsOneWidget);
    final bottomSheet = _compactPickerSheet(const Size(375, 812));
    expect(
      bottomSheet,
      findsOneWidget,
      reason:
          'wide sheets: ${_widePickerSheet().evaluate().length}; '
          'surface: ${tester.view.physicalSize}; '
          'dpr: ${tester.view.devicePixelRatio}',
    );
    expect(_widePickerSheet(), findsNothing);

    final cancel = find.descendant(of: bottomSheet, matching: find.text('取消'));
    final confirm = find.descendant(of: bottomSheet, matching: find.text('确定'));
    expect(cancel.hitTestable(), findsOneWidget);
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('目标上级分类(CAT-TARGET)'));
    await tester.pump();

    expect(bottomSheet, findsOneWidget);
    expect(
      tester
          .widget<UtenCategoryTreeView<ProductCategoryNode>>(
            find.byType(UtenCategoryTreeView<ProductCategoryNode>),
          )
          .selectedIds,
      {'target-parent'},
    );
    expect(confirm.hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(_compactPickerSheet(const Size(375, 812)), findsNothing);
    expect(find.text('目标上级分类'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpCategoryDialog(
  WidgetTester tester, {
  required List<ProductCategoryNode> tree,
  required ProductCategoryDetail editing,
  required Future<bool> Function(CategoryEditResult result) onSubmit,
  Size surfaceSize = const Size(1200, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = surfaceSize;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => CategoryEditDialog(
                    tree: tree,
                    editing: editing,
                    onSubmit: onSubmit,
                  ),
                ),
                child: const Text('打开分类编辑'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('打开分类编辑'));
  await tester.pumpAndSettle();
}

List<ProductCategoryNode> _categoryTree() => [
  ProductCategoryNode(
    id: 'original-parent',
    code: 'CAT-ORIGINAL',
    name: '原上级分类',
    level: 0,
    children: [
      ProductCategoryNode(
        id: 'current-category',
        code: 'CAT-CURRENT',
        name: '当前分类',
        level: 1,
        parentId: 'original-parent',
        children: const [],
      ),
    ],
  ),
  ProductCategoryNode(
    id: 'target-parent',
    code: 'CAT-TARGET',
    name: '目标上级分类',
    level: 0,
    children: const [],
  ),
];

Finder _pickerSheetAction(String label) {
  final sheet = _widePickerSheet();
  return find.descendant(of: sheet, matching: find.text(label));
}

Finder _widePickerSheet() => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == 420 &&
      widget.height == double.infinity,
);

Finder _compactPickerSheet(Size surfaceSize) => find.byWidgetPredicate(
  (widget) =>
      widget is SizedBox &&
      widget.width == null &&
      widget.height != null &&
      (widget.height! - surfaceSize.height * 0.85).abs() < 0.01,
);

Finder _textFieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);
