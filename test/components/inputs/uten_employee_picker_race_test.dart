import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
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
}
