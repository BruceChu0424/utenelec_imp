import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/department_node.dart';

UtenEmployeePickerItem _employee(int number, {String department = 'a'}) =>
    UtenEmployeePickerItem(
      id: 'e$number',
      name: '人员$number',
      employeeCode: 'UT$number',
      departmentId: department,
      departmentName: department == 'a' ? '甲部门' : '乙部门',
    );

List<DepartmentNode> _tree() => [
  DepartmentNode(
    id: 'root',
    code: 'ROOT',
    name: '管理中心',
    level: '管理中心',
    children: [
      DepartmentNode(
        id: 'a',
        code: 'A',
        name: '甲部门',
        level: '一级部门',
        children: [],
      ),
      DepartmentNode(
        id: 'b',
        code: 'B',
        name: '乙部门',
        level: '一级部门',
        children: [],
      ),
    ],
  ),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'known global departments use subtrees while historical or unavailable tree nodes retain exact membership without another lookup',
    () async {
      var reads = 0;
      Future<List<DepartmentNode>> unexpected() async {
        reads++;
        throw StateError('No extra metadata read');
      }

      expect(
        await employeePickerDepartmentScope(
          UtenEmployeePickerQuery(departmentId: 'root', organization: _tree()),
          loadDepartments: unexpected,
        ),
        (id: 'root', subtree: true, empty: false),
      );
      expect(
        await employeePickerDepartmentScope(
          UtenEmployeePickerQuery(
            departmentId: 'old-department',
            organization: _tree(),
          ),
          loadDepartments: unexpected,
        ),
        (id: 'old-department', subtree: false, empty: false),
      );
      expect(
        await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(departmentId: 'old-department'),
          loadDepartments: unexpected,
        ),
        (id: 'old-department', subtree: false, empty: false),
      );
      expect(reads, 0);
    },
  );

  testWidgets(
    'a denied continuation hides the earlier scope instead of presenting stale candidates',
    (tester) async {
      await _mount(
        tester,
        (query) async {
          if (query.page == 2) {
            throw ApiException(
              'READ_SCOPE_CHANGED',
              '数据访问范围已变化',
              httpStatus: 403,
            );
          }
          return _page(1, totalPages: 2);
        },
        multiple: true,
        initialSelection: [_employee(0)],
      );
      expect(
        find.byKey(const Key('uten-employee-picker-candidates')),
        findsNothing,
      );
      expect(find.text('数据访问范围已变化'), findsOneWidget);
      expect(find.text('已选 1 人'), findsOneWidget);
    },
  );

  testWidgets(
    'empty nonterminal first page is retryable without losing query or selection',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      final retry = Completer<UtenEmployeePickerPage>();
      var searching = 0;
      await _mount(
        tester,
        (query) async {
          calls.add(query);
          if (query.keyword != null) {
            if (++searching == 1) {
              return const UtenEmployeePickerPage(
                items: [],
                page: 1,
                totalPages: 3,
              );
            }
            return retry.future;
          }
          return _page(1);
        },
        multiple: true,
        initialSelection: [_employee(0)],
      );
      final search = _searchField();
      await tester.enterText(search, '人员');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(find.text('分页信息异常，请刷新后重新读取完整结果'), findsOneWidget);
      expect(tester.widget<TextField>(search).controller!.text, '人员');
      expect(find.text('已选 1 人'), findsOneWidget);
      await tester.tap(find.text('重试').last);
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      retry.complete(_page(1));
      await tester.pumpAndSettle();
      expect(_table(tester).selectedIds, contains('e0'));
      expect(calls.map((query) => query.page), [1, 1, 1]);
      expect(calls.last.keyword, '人员');
      expect(find.byType(UtenBusyOverlay), findsNothing);
    },
  );

  testWidgets(
    'an empty continuation keeps accepted rows and retries from a valid first page',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      var invalid = true;
      await _mount(
        tester,
        (query) async {
          calls.add(query);
          if (query.page == 2 && invalid) {
            return const UtenEmployeePickerPage(
              items: [],
              page: 2,
              totalPages: 3,
            );
          }
          return _page(query.page, totalPages: 3);
        },
        multiple: true,
        initialSelection: [_employee(0)],
      );
      expect(_table(tester).items, hasLength(40));
      expect(_table(tester).selectedIds, contains('e0'));
      expect(_table(tester).refreshError, isNotNull);
      expect(
        _table(tester).onLoadMore,
        isNull,
        reason: 'An invalid page must not cause automatic retry loops.',
      );
      invalid = false;
      _table(tester).onRetry!();
      await tester.pumpAndSettle();
      expect(calls.map((query) => query.page), [1, 2, 1, 2, 3]);
      expect(_table(tester).selectedIds, contains('e0'));
      expect(_table(tester).items, hasLength(120));
    },
  );

  testWidgets(
    'failed continuation retains rows and input with one guarded busy retry',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      final retry = Completer<UtenEmployeePickerPage>();
      var continuation = 0;
      await _mount(
        tester,
        (query) async {
          calls.add(query);
          if (query.keyword != null && query.page == 2) {
            if (++continuation == 1) {
              throw StateError('fixture connection interruption');
            }
            return retry.future;
          }
          return _page(query.page, totalPages: query.keyword == null ? 1 : 2);
        },
        multiple: true,
        initialSelection: [_employee(0)],
      );
      final search = _searchField();
      await tester.enterText(search, '人员');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(40));
      expect(_table(tester).selectedIds, contains('e0'));
      expect(tester.widget<TextField>(search).controller!.text, '人员');
      final repeat = _table(tester).onRetry!;
      repeat();
      repeat();
      await tester.pump();
      expect(find.byType(UtenBusyOverlay), findsOneWidget);
      expect(continuation, 2);
      retry.complete(_page(2, totalPages: 2));
      await tester.pumpAndSettle();
      expect(_table(tester).items, hasLength(80));
      expect(_table(tester).selectedIds, contains('e0'));
      expect(_table(tester).refreshError, isNull);
      expect(find.byType(UtenBusyOverlay), findsNothing);
      expect(calls.map((query) => query.page), [1, 1, 2, 1, 2]);
    },
  );

  testWidgets(
    'Enter dispatches before debounce, coalesces only active same-query reads and refreshes after completion',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      final pending = Completer<UtenEmployeePickerPage>();
      var searched = 0;
      await _mount(tester, (query) async {
        calls.add(query);
        if (query.keyword != null && ++searched == 1) return pending.future;
        return _page(1);
      });
      await tester.enterText(_searchField(), '人员');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      expect(calls.map((query) => query.keyword), [null, '人员']);
      await tester.tap(_searchField());
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump(const Duration(milliseconds: 350));
      expect(calls, hasLength(2));
      pending.complete(_page(1));
      await tester.pumpAndSettle();
      await tester.tap(_searchField());
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(calls.map((query) => query.keyword), [null, '人员', '人员']);
    },
  );

  test(
    'department clicks intersect a fixed workflow scope instead of widening it',
    () async {
      var metadataReads = 0;
      Future<List<DepartmentNode>> tree() async {
        metadataReads++;
        return _tree();
      }

      expect(
        await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(),
          departmentId: 'a',
          loadDepartments: tree,
        ),
        (id: 'a', subtree: false, empty: false),
      );
      expect(metadataReads, 0);
      expect(
        (await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(departmentId: 'b'),
          departmentId: 'a',
          includeSubtree: true,
          loadDepartments: tree,
        )).empty,
        true,
      );
      expect(
        await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(departmentId: 'root'),
          departmentId: 'a',
          loadDepartments: tree,
        ),
        (id: 'a', subtree: false, empty: false),
      );
      expect(
        await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(departmentId: 'a'),
          departmentId: 'root',
          includeSubtree: true,
          loadDepartments: tree,
        ),
        (id: 'a', subtree: true, empty: false),
      );
      expect(
        (await employeePickerDepartmentScope(
          const UtenEmployeePickerQuery(departmentId: 'a'),
          departmentId: 'root',
          loadDepartments: tree,
        )).empty,
        true,
      );
    },
  );

  testWidgets(
    'all staff pages complete once and cross-page selection survives local scrolling',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      await _mount(tester, (query) async {
        calls.add(query);
        return _page(query.page, totalPages: 3);
      }, multiple: true);
      expect(calls.map((query) => query.page), [1, 2, 3]);
      await tester.tap(find.byKey(const ValueKey('employee-picker-item-e0')));
      await tester.pump();
      var table = _table(tester);
      expect(table.items, hasLength(120));
      expect(table.items.last.id, 'e119');
      expect(table.onLoadMore, isNull);
      table.onRowSelectionChanged!(table.items.last, true);
      await tester.pump();
      table = _table(tester);
      expect(table.selectedIds, containsAll(['e0', 'e119']));
      expect(calls.map((query) => query.page), [1, 2, 3]);
      expect(find.text('加载更多'), findsNothing);
    },
  );

  testWidgets(
    'a department without loaded staff remains reachable through a server-filtered first page',
    (tester) async {
      final calls = <UtenEmployeePickerQuery>[];
      await _mount(tester, (query) async {
        calls.add(query);
        return UtenEmployeePickerPage(
          items: [
            for (var index = 0; index < 40; index++)
              _employee(
                index,
                department: query.departmentId == 'b' ? 'b' : 'a',
              ),
          ],
          page: query.page,
          totalPages: 1,
        );
      });
      await tester.tap(find.text('管理中心'));
      await tester.pumpAndSettle();
      expect(find.text('乙部门'), findsOneWidget);
      await tester.tap(find.text('乙部门'));
      await tester.pumpAndSettle();
      expect(calls.last.departmentId, 'b');
      expect(calls.last.page, 1);
      final table = tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
        find.byKey(const Key('uten-employee-picker-candidates')),
      );
      expect(table.items.every((item) => item.departmentId == 'b'), true);
    },
  );

  testWidgets(
    'typing retires an old search immediately and does not query all pages',
    (tester) async {
      final old = Completer<UtenEmployeePickerPage>();
      final calls = <UtenEmployeePickerQuery>[];
      await _mount(tester, (query) async {
        calls.add(query);
        if (query.keyword == '旧') return old.future;
        return UtenEmployeePickerPage(
          items: [_employee(query.keyword == '新' ? 999 : 0)],
          page: query.page,
          totalPages: 1,
        );
      });
      final search = find
          .descendant(
            of: find.byKey(const Key('uten-employee-picker-search')),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(search, '旧');
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pump();
      await tester.enterText(search, '新');
      old.complete(
        UtenEmployeePickerPage(
          items: [_employee(888)],
          page: 1,
          totalPages: 1000,
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('employee-picker-item-e888')),
        findsNothing,
      );
      await tester.pump(const Duration(milliseconds: 310));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('employee-picker-item-e999')),
        findsOneWidget,
      );
      expect(calls.map((query) => query.keyword), [null, '旧', '新']);
      expect(calls.every((query) => query.page == 1), true);
    },
  );
}

Future<void> _mount(
  WidgetTester tester,
  UtenEmployeePickerPagedLoader loader, {
  bool multiple = false,
  List<UtenEmployeePickerItem> initialSelection = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1500, 800);
  addTearDown(() {
    tester.view.resetDevicePixelRatio();
    tester.view.resetPhysicalSize();
  });
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: UtenEmployeeSelectionPanel(
          pagedLoader: loader,
          departmentTreeLoader: () async => _tree(),
          multiple: multiple,
          initialSelection: initialSelection,
          onConfirm: (_) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

UtenEmployeePickerPage _page(int page, {int totalPages = 1}) =>
    UtenEmployeePickerPage(
      items: List.generate(40, (index) => _employee((page - 1) * 40 + index)),
      page: page,
      totalPages: totalPages,
    );

MasterDataTableView<UtenEmployeePickerItem> _table(WidgetTester tester) =>
    tester.widget<MasterDataTableView<UtenEmployeePickerItem>>(
      find.byKey(const Key('uten-employee-picker-candidates')),
    );

Finder _searchField() => find
    .descendant(
      of: find.byKey(const Key('uten-employee-picker-search')),
      matching: find.byType(TextField),
    )
    .first;
