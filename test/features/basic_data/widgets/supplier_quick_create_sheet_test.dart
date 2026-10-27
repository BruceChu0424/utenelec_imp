import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/repositories/supplier_category_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/supplier_quick_create_sheet.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _Categories implements SupplierCategoryRepository {
  @override
  Future<List<ProductCategoryNode>> tree() async => [
    ProductCategoryNode(
      id: 'parent',
      code: 'P',
      name: '供应商父分类',
      level: 0,
      children: [
        ProductCategoryNode(
          id: 'child',
          code: 'C',
          name: '供应商子分类',
          level: 1,
          children: const [],
        ),
      ],
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final size in [const Size(1200, 900), const Size(390, 844)]) {
    testWidgets('供应商快捷新建分类暂存后确认，改选取消不改变表单 $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            supplierCategoryRepositoryProvider.overrideWithValue(_Categories()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: Consumer(
                builder: (context, ref, _) => TextButton(
                  onPressed: () => showSupplierQuickCreateSheet(context, ref),
                  child: const Text('快捷新建'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('快捷新建'));
      await tester.pumpAndSettle();
      final form = tester.state<MasterEditFormState>(
        find.byType(MasterEditForm),
      );
      final category = find.byKey(
        const ValueKey('supplier-category-picker-field'),
      );
      await tester.ensureVisible(category);
      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(tester.widget<UtenButton>(_pickerAction('确定')).onPressed, isNull);
      expect(
        find.byType(UtenCategoryTreeView<ProductCategoryNode>),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('收起供应商父分类'));
      await tester.pumpAndSettle();
      expect(_categoryRow('child'), findsNothing);
      await tester.tap(find.byTooltip('展开供应商父分类'));
      await tester.pumpAndSettle();
      await tester.tap(_categoryRow('child'));
      await tester.pump();
      expect(find.text('选择供应商分类'), findsOneWidget);
      expect(form.controller.customValues['categoryId'], isNull);
      await tester.tap(_pickerAction('确定'));
      await tester.pumpAndSettle();
      expect(form.controller.customValues['categoryId'], 'child');
      expect(
        find.descendant(of: category, matching: find.text('供应商子分类')),
        findsOneWidget,
      );

      await tester.tap(category);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UtenCategoryTreeView<ProductCategoryNode>>(
              find.byType(UtenCategoryTreeView<ProductCategoryNode>),
            )
            .selectedIds,
        {'child'},
      );
      await tester.tap(_categoryRow('parent'));
      await tester.pump();
      expect(form.controller.customValues['categoryId'], 'child');
      await tester.tap(_pickerAction('取消'));
      await tester.pumpAndSettle();
      expect(form.controller.customValues['categoryId'], 'child');
      expect(
        find.descendant(of: category, matching: find.text('供应商子分类')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}

Finder _pickerAction(String label) => find.descendant(
  of: find.byType(UtenPickerConfirmBar),
  matching: find.widgetWithText(UtenButton, label),
);

Finder _categoryRow(String id) => find.byKey(ValueKey('hierarchy-row:$id'));
