import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/layout/uten_split_view.dart';
import 'package:uten_imp/core/network/api_exception.dart';

const _sales = UtenEmployeePickerItem(
  id: 'sales-1',
  name: '张三',
  employeeCode: 'UT001',
  departmentId: 'sales',
  departmentName: '销售部',
  subtitle: '在职',
);
const _production = UtenEmployeePickerItem(
  id: 'production-1',
  name: '李四',
  employeeCode: 'UT002',
  departmentId: 'production',
  departmentName: '生产部',
);
const _candidates = [_sales, _production];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('single picker uses the customer width and confirms explicitly', (
    tester,
  ) async {
    await _surface(tester, const Size(1920, 900));
    UtenEmployeePickerItem? changed;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEmployeePicker(
            loader: (_) async => _candidates,
            onChanged: (item) => changed = item,
          ),
        ),
      ),
    );
    await tester.tap(find.text('请选择员工'));
    await tester.pumpAndSettle();
    expect(find.byType(UtenSplitView), findsOneWidget);
    expect(tester.getSize(find.byType(UtenEmployeeSelectionPanel)).width, 960);
    await tester.tap(
      find.byKey(const ValueKey('employee-picker-item-sales-1')),
    );
    await tester.pump();
    expect(changed, isNull);
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    await tester.pumpAndSettle();
    expect(changed?.id, _sales.id);
  });

  testWidgets(
    'department IDs keep same-name groups separate and missing IDs safe',
    (tester) async {
      await _surface(tester, const Size(1200, 900));
      const rows = [
        UtenEmployeePickerItem(
          id: 'a',
          name: '甲',
          departmentId: 'd1',
          departmentName: '同名部门',
        ),
        UtenEmployeePickerItem(
          id: 'b',
          name: '乙',
          departmentId: 'd2',
          departmentName: '同名部门',
        ),
        UtenEmployeePickerItem(
          id: 'c',
          name: '丙',
          departmentName: '不得充当分组',
          subtitle: '负责18个客户',
        ),
      ];
      await _panel(tester, loader: (_) async => rows);
      final departmentLabels = find.text('同名部门');
      // Two tree nodes plus two employee subtitles.
      expect(departmentLabels, findsNWidgets(4));
      await tester.tap(departmentLabels.at(0));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-b')),
        findsNothing,
      );
      await tester.tap(find.text('同名部门').at(1));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-a')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-b')),
        findsOneWidget,
      );
      await tester.tap(find.text('未提供部门'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-c')),
        findsOneWidget,
      );
      expect(find.text('不得充当分组'), findsNothing);
      expect(find.text('负责18个客户'), findsNothing);
      expect(find.text('不得充当分组 · 负责18个客户'), findsOneWidget);
    },
  );

  testWidgets(
    'department keyword finds authorized baseline without widening loader',
    (tester) async {
      final keywords = <String?>[];
      await _panel(
        tester,
        loader: (query) async {
          keywords.add(query);
          return query == null ? _candidates : const [];
        },
      );
      await _search(tester, '销售部');
      expect(keywords, [null, '销售部']);
      expect(
        find.byKey(const ValueKey('employee-picker-item-sales-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('employee-picker-item-production-1')),
        findsNothing,
      );
    },
  );

  testWidgets('multi selection survives department and keyword changes', (
    tester,
  ) async {
    List<UtenEmployeePickerItem>? result;
    await _panel(
      tester,
      multiple: true,
      onConfirm: (items) => result = items,
      loader: (query) async => query == null
          ? _candidates
          : _candidates
                .where((item) => item.employeeCode!.contains(query))
                .toList(),
    );
    await tester.tap(find.text('销售部').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-picker-item-sales-1')),
    );
    await _search(tester, 'UT002');
    await tester.tap(
      find.byKey(const ValueKey('employee-picker-item-production-1')),
    );
    await tester.pump();
    expect(find.text('已选 2 人'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '确定'));
    expect(result?.map((item) => item.id), ['sales-1', 'production-1']);
  });

  testWidgets(
    'multi cancel leaves field unchanged and clear confirms an empty list',
    (tester) async {
      List<UtenEmployeePickerItem>? changed;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UtenEmployeeMultiPicker(
              initialSelection: const [_sales],
              loader: (_) async => _candidates,
              onChanged: (items) => changed = items,
            ),
          ),
        ),
      );
      await tester.tap(find.text('已选 1 人'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(changed, isNull);
      expect(find.text(_sales.displayName), findsOneWidget);
      await tester.tap(find.text('已选 1 人'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('清空'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
      expect(changed, isEmpty);
      expect(find.text(_sales.displayName), findsNothing);
    },
  );

  testWidgets(
    'disabled candidates cannot be selected and retry recovers errors',
    (tester) async {
      var attempts = 0;
      List<UtenEmployeePickerItem>? selected;
      await _panel(
        tester,
        onConfirm: (items) => selected = items,
        loader: (_) async {
          if (attempts++ == 0) throw StateError('temporary failure');
          return const [
            UtenEmployeePickerItem(
              id: 'blocked',
              name: '不可开通',
              enabled: false,
              disabledReason: '缺少手机号',
            ),
            _sales,
          ];
        },
      );
      expect(find.text('人员列表加载失败，请重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('employee-picker-item-blocked')),
      );
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
      expect(find.text('缺少手机号'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      expect(selected, isNull);
    },
  );

  testWidgets('single replacement clears the original ID highlight', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: UtenEmployeeSelectionPanel(
            selectedId: _sales.id,
            loader: (_) async => _candidates,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('employee-picker-item-production-1')),
    );
    await tester.pump();
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('employee-picker-item-sales-1')),
          )
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<ListTile>(
            find.byKey(const ValueKey('employee-picker-item-production-1')),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('candidate API guidance is shown without raw exception details', (
    tester,
  ) async {
    await _panel(
      tester,
      loader: (_) async {
        throw ApiException('VALIDATION_FAILED', '候选人员超过5000人，请输入姓名或工号缩小范围');
      },
    );
    expect(find.text('候选人员超过5000人，请输入姓名或工号缩小范围'), findsOneWidget);
    expect(find.textContaining('VALIDATION_FAILED'), findsNothing);
    expect(find.textContaining('ApiException'), findsNothing);
  });

  testWidgets(
    'new input invalidates an older response before debounce completes',
    (tester) async {
      final old = Completer<List<UtenEmployeePickerItem>>();
      await _panel(
        tester,
        loader: (query) async {
          if (query == '旧') return old.future;
          return query == null ? const [] : const [_production];
        },
      );
      await tester.enterText(_searchField(), '旧');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.enterText(_searchField(), '新');
      old.complete(const [_sales]);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('employee-picker-item-sales-1')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-production-1')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'compact dark large-text panel fits and privacy mode omits departments',
    (tester) async {
      await _surface(tester, const Size(375, 812));
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.4)),
            child: child!,
          ),
          home: Scaffold(
            body: UtenEmployeeSelectionPanel(
              multiple: true,
              loader: (_) async => _candidates,
              onConfirm: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const Key('uten-employee-picker-departments')),
        findsOneWidget,
      );
      await _panel(
        tester,
        loader: (_) async => _candidates,
        showDepartmentFilter: false,
      );
      expect(
        find.byKey(const Key('uten-employee-picker-departments')),
        findsNothing,
      );
      expect(find.text('全部部门'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _searchField() => find.descendant(
  of: find.byKey(const Key('uten-employee-picker-search')),
  matching: find.byType(TextField),
);

Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(_searchField(), query);
  await tester.pump(const Duration(milliseconds: 310));
  await tester.pumpAndSettle();
}

Future<void> _surface(WidgetTester tester, Size size) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> _panel(
  WidgetTester tester, {
  required UtenEmployeePickerLoader loader,
  bool multiple = false,
  bool showDepartmentFilter = true,
  ValueChanged<List<UtenEmployeePickerItem>>? onConfirm,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UtenEmployeeSelectionPanel(
          loader: loader,
          multiple: multiple,
          showDepartmentFilter: showDepartmentFilter,
          onConfirm: onConfirm ?? (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
