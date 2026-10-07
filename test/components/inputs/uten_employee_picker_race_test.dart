import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('older candidate response cannot overwrite latest search', (
    tester,
  ) async {
    final oldResult = Completer<List<UtenEmployeePickerItem>>();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final newResult = Completer<List<UtenEmployeePickerItem>>();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
        child: MaterialApp(
          home: Scaffold(
            body: UtenEmployeePicker(
              label: '接手人',
              loader: (keyword) {
                if (keyword == '旧') return oldResult.future;
                if (keyword == '新') return newResult.future;
                return Future.value(const <UtenEmployeePickerItem>[]);
              },
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('请选择员工'));
    await tester.pumpAndSettle();
    final search = find.byType(TextField).last;

    await tester.enterText(search, '旧');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.enterText(search, '新');
    await tester.pump(const Duration(milliseconds: 350));

    newResult.complete(const [
      UtenEmployeePickerItem(id: 'new-1', name: '最新候选'),
    ]);
    await tester.pump();
    expect(find.text('最新候选'), findsOneWidget);

    oldResult.complete(const [
      UtenEmployeePickerItem(id: 'old-1', name: '过期候选'),
    ]);
    await tester.pump();
    expect(find.text('最新候选'), findsOneWidget);
    expect(find.text('过期候选'), findsNothing);
  });

  testWidgets('old hydration cannot replace a newer same-ID full snapshot', (
    tester,
  ) async {
    final oldHydration = Completer<List<UtenEmployeePickerItem>>();
    late StateSetter update;
    var initial = const UtenEmployeePickerItem(id: 'same', name: '张三');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return UtenEmployeePicker(
                initial: initial,
                loader: (keyword) => keyword == null
                    ? Future.value(const [])
                    : oldHydration.future,
                onChanged: (_) {},
              );
            },
          ),
        ),
      ),
    );
    update(
      () => initial = const UtenEmployeePickerItem(
        id: 'same',
        name: '张三',
        employeeCode: 'NEW',
        departmentId: 'new-department',
        departmentName: '新部门',
        subtitle: '新岗位',
      ),
    );
    await tester.pump();
    oldHydration.complete(const [
      UtenEmployeePickerItem(
        id: 'same',
        name: '张三',
        employeeCode: 'OLD',
        departmentId: 'old-department',
        departmentName: '旧部门',
        subtitle: '旧岗位',
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('张三(NEW)'), findsOneWidget);
    expect(find.text('张三(OLD)'), findsNothing);
    await tester.tap(find.text('张三(NEW)'));
    await tester.pumpAndSettle();
    final selection = tester
        .widget<UtenEmployeeSelectionPanel>(
          find.byType(UtenEmployeeSelectionPanel),
        )
        .initialSelection
        .single;
    expect(selection.departmentId, 'new-department');
    expect(selection.subtitle, '新岗位');
  });

  for (final multiple in [false, true]) {
    for (final change in ['initial', 'scope', 'equivalent rebuild']) {
      testWidgets(
        '${multiple ? 'multi' : 'single'} pending selection respects $change',
        (tester) async {
          const first = UtenEmployeePickerItem(
            id: 'first',
            name: '甲',
            employeeCode: 'A',
          );
          const second = UtenEmployeePickerItem(
            id: 'second',
            name: '乙',
            employeeCode: 'B',
          );
          late StateSetter update;
          var scope = 'first-scope';
          var initial = <UtenEmployeePickerItem>[];
          List<UtenEmployeePickerItem>? changed;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: StatefulBuilder(
                  builder: (context, setState) {
                    update = setState;
                    // This deliberately creates a fresh loader/list on every rebuild.
                    return multiple
                        ? UtenEmployeeMultiPicker(
                            candidateScopeKey: scope,
                            initialSelection: [...initial],
                            loader: (_) async => [first, second],
                            onChanged: (items) => changed = items,
                          )
                        : UtenEmployeePicker(
                            candidateScopeKey: scope,
                            initial: initial.firstOrNull,
                            loader: (_) async => [first, second],
                            onChanged: (item) => changed = [?item],
                          );
                  },
                ),
              ),
            ),
          );
          await tester.tap(find.text(multiple ? '请选择人员' : '请选择员工'));
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('employee-picker-item-first')),
          );
          await tester.pump();
          update(() {
            if (change == 'initial') initial = [second];
            if (change == 'scope') scope = 'second-scope';
          });
          await tester.pump();
          await tester.tap(find.widgetWithText(FilledButton, '确定'));
          await tester.pumpAndSettle();
          if (change == 'equivalent rebuild') {
            expect(changed?.map((item) => item.id), ['first']);
          } else {
            expect(changed, isNull);
            if (change == 'initial') expect(find.text('乙(B)'), findsOneWidget);
          }
        },
      );
    }
  }

  testWidgets(
    'embedded panel drops pending candidates and picks when scope changes',
    (tester) async {
      final oldResult = Completer<List<UtenEmployeePickerItem>>();
      late StateSetter update;
      var scope = 'old';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return UtenEmployeeSelectionPanel(
                  candidateScopeKey: scope,
                  initialSelection: const [
                    UtenEmployeePickerItem(id: 'old', name: '旧选择'),
                  ],
                  loader: (_) => scope == 'old'
                      ? oldResult.future
                      : Future.value(const [
                          UtenEmployeePickerItem(id: 'new', name: '新候选'),
                        ]),
                );
              },
            ),
          ),
        ),
      );
      update(() => scope = 'new');
      await tester.pumpAndSettle();
      oldResult.complete(const [
        UtenEmployeePickerItem(id: 'stale', name: '过期候选'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('新候选'), findsOneWidget);
      expect(find.text('过期候选'), findsNothing);
      expect(find.text('已选择：旧选择'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
    },
  );
}
