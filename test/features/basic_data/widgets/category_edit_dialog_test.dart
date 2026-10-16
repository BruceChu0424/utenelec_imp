import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/category_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_category_tree_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_mixin.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import 'package:uten_imp/shared/widgets/uten_location_field.dart';

void main() {
  testWidgets('输入时检查全局占用并标红，换成可用前缀后才允许保存', (tester) async {
    final checked = <String>[];
    CategoryEditResult? submitted;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async {
        checked.add(prefix);
        return _availability(prefix, available: prefix != 'UG');
      },
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );
    await tester.enterText(_textFieldWithLabel('名称'), '货品分类');
    await tester.enterText(_prefixField(), 'ug');
    await tester.pump(const Duration(milliseconds: 200));
    expect(checked, isEmpty);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(checked, ['UG']);
    expect(find.text('编号前缀“UG”已被占用，请更换后再保存。'), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    final field = tester.widget<TextField>(_prefixField());
    final errorColor = Theme.of(
      tester.element(_prefixField()),
    ).colorScheme.error;
    expect(field.decoration!.enabledBorder!.borderSide.color, errorColor);
    expect(field.decoration!.focusedBorder!.borderSide.color, errorColor);
    expect(field.controller!.text, 'ug');

    await tester.enterText(_prefixField(), 'ugx');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.textContaining('已被占用'), findsNothing);
    expect(_submitButton(tester, '创建').onPressed, isNotNull);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submitted!.codePrefix, 'UGX');
    expect(checked, ['UG', 'UGX', 'UGX']);
  });

  testWidgets('快速更换输入后忽略旧请求结果，清空也不会被旧结果标红', (tester) async {
    final requests = <String, Completer<CategoryPrefixAvailability>>{};
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) =>
          (requests[prefix] = Completer<CategoryPrefixAvailability>()).future,
      onSubmit: (_) async => true,
    );
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(_prefixField(), 'UGX');
    await tester.pump(const Duration(milliseconds: 350));
    requests['UGX']!.complete(_availability('UGX'));
    await tester.pumpAndSettle();
    requests['UG']!.complete(_availability('UG', available: false));
    await tester.pumpAndSettle();
    expect(find.textContaining('已被占用'), findsNothing);
    expect(_submitButton(tester, '创建').onPressed, isNotNull);

    await tester.enterText(_prefixField(), 'OLD');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(_prefixField(), '');
    await tester.pump();
    requests['OLD']!.complete(_availability('OLD', available: false));
    await tester.pumpAndSettle();
    expect(find.textContaining('已被占用'), findsNothing);
    expect(_submitButton(tester, '创建').onPressed, isNotNull);
  });

  testWidgets('检查失败阻止保存并允许原输入重试', (tester) async {
    var attempts = 0;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async {
        if (++attempts == 1) throw StateError('offline');
        return _availability(prefix);
      },
      onSubmit: (_) async => true,
    );
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法检查编号前缀，请重新检查后保存。'), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    await tester.tap(find.byTooltip('重新检查编号前缀'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(find.textContaining('暂时无法检查'), findsNothing);
    expect(_submitButton(tester, '创建').onPressed, isNotNull);
    expect(tester.widget<TextField>(_prefixField()).controller!.text, 'UG');
  });

  testWidgets('保存前重新检查，已被抢占时保留输入且不提交', (tester) async {
    var attempts = 0;
    var submitted = false;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async =>
          _availability(prefix, available: ++attempts == 1),
      onSubmit: (_) async {
        submitted = true;
        return true;
      },
    );
    await tester.enterText(_textFieldWithLabel('名称'), '货品分类');
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
    expect(submitted, isFalse);
    expect(find.text('编号前缀“UG”已被占用，请更换后再保存。'), findsOneWidget);
    expect(tester.widget<TextField>(_prefixField()).controller!.text, 'UG');
  });

  testWidgets('事务保存被拒绝后刷新占用并标红', (tester) async {
    var attempts = 0;
    var submissions = 0;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async =>
          _availability(prefix, available: ++attempts <= 2),
      onSubmit: (_) async {
        submissions++;
        return false;
      },
    );
    await tester.enterText(_textFieldWithLabel('名称'), '货品分类');
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submissions, 1);
    expect(attempts, 3);
    expect(find.text('编号前缀“UG”已被占用，请更换后再保存。'), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
  });

  testWidgets('格式错误即时标红且不查询，留空继承可以保存', (tester) async {
    var checks = 0;
    CategoryEditResult? submitted;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async {
        checks++;
        return _availability(prefix);
      },
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );
    await tester.enterText(_textFieldWithLabel('名称'), '继承分类');
    await tester.enterText(_prefixField(), '1UG');
    await tester.pumpAndSettle();
    expect(find.text('编号前缀须以字母开头，只能包含 1–8 位字母或数字'), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    expect(checks, 0);
    await tester.enterText(_prefixField(), '');
    await tester.pump();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submitted!.codePrefix, '');
    expect(checks, 0);
  });

  testWidgets('仅移动排序权限不触发前缀查询，保留原前缀保存', (tester) async {
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
        path: '',
        childCount: 0,
        codePrefix: 'UG',
      ),
      canEditFields: false,
      onCheckPrefix: (_) async => throw StateError('不应查询'),
      onSubmit: (result) async {
        submitted = result;
        return true;
      },
    );
    expect(tester.widget<TextField>(_prefixField()).readOnly, isTrue);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(submitted!.codePrefix, 'UG');
  });

  testWidgets('关闭对话框后在途检查结果不再修改状态', (tester) async {
    final pending = Completer<CategoryPrefixAvailability>();
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (_) => pending.future,
      onSubmit: (_) async => true,
    );
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    pending.complete(_availability('UG', available: false));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(CategoryEditDialog), findsNothing);
  });

  testWidgets('已创建成功的草稿可完成收尾，不再把自己的前缀当成占用', (tester) async {
    var checks = 0;
    var submissions = 0;
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (prefix) async {
        checks++;
        return _availability(prefix, available: false);
      },
      onSubmit: (_) async {
        submissions++;
        return true;
      },
    );
    final state =
        tester.state(find.byType(CategoryEditDialog))
            as FormDraftMixin<CategoryEditDialog>;
    await state.restoreFormDraft(<String, dynamic>{
      'text': {'prefixCtl': 'UG', 'nameCtl': '已创建分类'},
      'serverCreated': true,
    });
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(checks, 0);
    expect(tester.widget<TextField>(_prefixField()).readOnly, isTrue);
    expect(_submitButton(tester, '创建').onPressed, isNotNull);
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();
    expect(submissions, 0);
    expect(find.byType(CategoryEditDialog), findsNothing);
  });

  testWidgets('紧凑屏占用提示可直接看到且输入框仍可修改', (tester) async {
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      surfaceSize: const Size(375, 812),
      onCheckPrefix: (prefix) async => _availability(prefix, available: false),
      onSubmit: (_) async => true,
    );
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('编号前缀“UG”已被占用，请更换后再保存。').hitTestable(), findsOneWidget);
    expect(tester.widget<TextField>(_prefixField()).readOnly, isFalse);
    expect(find.text('创建').hitTestable(), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('检查回包前缀不匹配时禁止保存并可重试', (tester) async {
    await _pumpCategoryDialog(
      tester,
      tree: _categoryTree(),
      onCheckPrefix: (_) async => _availability('OTHER'),
      onSubmit: (_) async => true,
    );
    await tester.enterText(_prefixField(), 'UG');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('暂时无法检查编号前缀，请重新检查后保存。'), findsOneWidget);
    expect(_submitButton(tester, '创建').onPressed, isNull);
    expect(find.byTooltip('重新检查编号前缀'), findsOneWidget);
  });

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

    await tester.tap(find.text('目标上级分类'));
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
    await tester.tap(find.text('目标上级分类'));
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

    await tester.tap(find.text('目标上级分类'));
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
  ProductCategoryDetail? editing,
  bool canEditFields = true,
  Future<CategoryPrefixAvailability> Function(String)? onCheckPrefix,
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
                    canEditFields: canEditFields,
                    onCheckPrefix: onCheckPrefix,
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

Finder _prefixField() => find.byWidgetPredicate(
  (widget) =>
      widget is TextField &&
      widget.textCapitalization == TextCapitalization.characters,
);

UtenButton _submitButton(WidgetTester tester, String label) =>
    tester.widget<UtenButton>(
      find.ancestor(of: find.text(label), matching: find.byType(UtenButton)),
    );

CategoryPrefixAvailability _availability(
  String prefix, {
  bool available = true,
}) =>
    CategoryPrefixAvailability(normalizedPrefix: prefix, available: available);
