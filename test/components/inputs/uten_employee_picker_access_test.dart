import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_employee_multi_picker.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _person = UtenEmployeePickerItem(
  id: 'employee-id-not-user-id',
  name: '同名员工',
  employeeCode: 'UT006',
  departmentId: 'sales',
  departmentName: '销售部',
);
final _identity = StateProvider<AuthenticatedScope?>(
  (_) => const AuthenticatedScope(userId: 'account-a', epoch: 1),
);
final _server = StateProvider<String>((_) => 'https://server-a.test');
final _permissions = StateProvider<Set<String>>((_) => {'employee:view'});

void main() {
  for (final multiple in [false, true]) {
    for (final boundary in ['identity', 'server', 'permissions']) {
      testWidgets(
        '$boundary invalidates open ${multiple ? 'multi' : 'single'} picker even after ABA',
        (tester) async {
          final pending = Completer<List<UtenEmployeePickerItem>>();
          final changed = <Object?>[];
          final container = await _pump(
            tester,
            multiple
                ? UtenEmployeeMultiPicker(
                    initialSelection: const [_person],
                    loader: (_) => pending.future,
                    onChanged: changed.add,
                  )
                : UtenEmployeePicker(
                    initial: _person,
                    loader: (_) => pending.future,
                    onChanged: changed.add,
                  ),
          );
          await tester.tap(find.byType(InputDecorator));
          await tester.pump(const Duration(milliseconds: 350));
          expect(find.byType(UtenEmployeeSelectionPanel), findsOneWidget);
          switch (boundary) {
            case 'identity':
              container.read(_identity.notifier).state =
                  const AuthenticatedScope(userId: 'account-b', epoch: 2);
              await tester.pump();
              container.read(_identity.notifier).state =
                  const AuthenticatedScope(userId: 'account-a', epoch: 1);
            case 'server':
              container.read(_server.notifier).state = 'https://server-b.test';
              await tester.pump();
              container.read(_server.notifier).state = 'https://server-a.test';
            case 'permissions':
              container.read(_permissions.notifier).state = {};
              await tester.pump();
              container.read(_permissions.notifier).state = {'employee:view'};
          }
          pending.complete(const [_person]);
          await tester.pumpAndSettle();
          expect(find.byType(UtenEmployeeSelectionPanel), findsNothing);
          expect(changed, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'invalidation removes only its own popup underneath a newer dialog',
    (tester) async {
      final container = await _pump(
        tester,
        UtenEmployeePicker(
          loader: (_) async => const [_person],
          onChanged: (_) {},
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(UtenEmployeeSelectionPanel));
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) => const AlertDialog(content: Text('保留新对话框')),
        ),
      );
      await tester.pumpAndSettle();
      container.read(_permissions.notifier).state = {};
      await tester.pumpAndSettle();
      expect(find.text('保留新对话框'), findsOneWidget);
      expect(
        find.byType(UtenEmployeeSelectionPanel, skipOffstage: false),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late same-ID hydration cannot import metadata from old server', (
    tester,
  ) async {
    final pending = Completer<List<UtenEmployeePickerItem>>();
    final container = await _pump(
      tester,
      UtenEmployeePicker(
        initial: const UtenEmployeePickerItem(
          id: 'employee-id-not-user-id',
          name: '原姓名',
        ),
        loader: (_) => pending.future,
        onChanged: (_) => fail('hydration must not submit'),
      ),
    );
    container.read(_server.notifier).state = 'https://server-b.test';
    await tester.pump();
    pending.complete(const [_person]);
    await tester.pumpAndSettle();
    expect(find.text('原姓名'), findsOneWidget);
    expect(find.text(_person.displayName), findsNothing);
  });

  testWidgets(
    'initial selection cannot confirm during load or failure, retry restores confirmation',
    (tester) async {
      final pending = Completer<List<UtenEmployeePickerItem>>();
      var calls = 0;
      await _pump(
        tester,
        UtenEmployeePicker(
          initial: _person,
          loader: (_) =>
              calls++ == 0 ? pending.future : Future.value(const [_person]),
          onChanged: (_) {},
        ),
      );
      await tester.tap(find.byType(InputDecorator));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      pending.completeError(StateError('candidate request failed'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确定'))
            .onPressed,
        isNotNull,
      );
    },
  );

  for (final keyword in ['同名员工', 'UT006']) {
    testWidgets(
      'authoritative empty search for $keyword does not resurrect baseline',
      (tester) async {
        await _pump(
          tester,
          UtenEmployeePicker(
            loader: (query) async => query == null ? const [_person] : const [],
            onChanged: (_) {},
          ),
        );
        await tester.tap(find.byType(InputDecorator));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const ValueKey('employee-picker-item-employee-id-not-user-id'),
          ),
          findsOneWidget,
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const Key('uten-employee-picker-search')),
            matching: find.byType(TextField),
          ),
          keyword,
        );
        await tester.pump(const Duration(milliseconds: 310));
        await tester.pumpAndSettle();
        expect(
          find.byKey(
            const ValueKey('employee-picker-item-employee-id-not-user-id'),
          ),
          findsNothing,
        );
      },
    );
  }
}

Future<ProviderContainer> _pump(WidgetTester tester, Widget picker) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      isSuperAdminProvider.overrideWithValue(false),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: picker)),
    ),
  );
  await tester.pump();
  return container;
}
