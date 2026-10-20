import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/models/unit_node.dart';
import 'package:uten_imp/features/basic_data/repositories/unit_repository.dart';
import 'package:uten_imp/features/rd_task/models/rd_task.dart';
import 'package:uten_imp/features/rd_task/repositories/rd_task_repository.dart';
import 'package:uten_imp/features/rd_task/widgets/rd_initial_basic_unit_dialog.dart';

class _Units extends Fake implements UnitRepository {
  int calls = 0;
  bool fail = false;
  @override
  Future<List<UnitListItem>> dict() async {
    calls++;
    if (fail) throw Exception('offline');
    return const [UnitListItem(id: 'piece', name: '个', status: '使用')];
  }
}

class _Tasks extends Fake implements RdTaskRepository {
  RdInitialUnitContext context = const RdInitialUnitContext(allowed: true);
  @override
  Future<RdInitialUnitContext> initialBasicUnitContext(String id) async =>
      context;
}

const _task = RdTaskRow(
  id: 'task',
  taskNo: 'RD-1',
  title: '核对组件单位',
  category: 'OTHER',
  status: 'OPEN',
  priority: 'NORMAL',
  rowVersion: 1,
);

void main() {
  Future<void> pump(WidgetTester tester, _Units units, _Tasks tasks) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          unitRepositoryProvider.overrideWithValue(units),
          rdTaskRepositoryProvider.overrideWithValue(tasks),
        ],
        child: const MaterialApp(
          locale: Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: RdInitialBasicUnitDialog(task: _task)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'unit and original-source evidence require explicit input; no default unit guess',
    (tester) async {
      await pump(tester, _Units(), _Tasks());
      final choice = tester.widget<UtenDropdownField>(
        find.byKey(const Key('rd-initial-unit-choice')),
      );
      expect(choice.value, isNull);
      await tester.tap(find.byKey(const Key('rd-initial-unit-confirm')));
      await tester.pump();
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('rd-initial-unit-choice')),
            )
            .errorMessage,
        isNotNull,
      );
      final field = tester.widget<TextField>(
        find.byKey(const Key('rd-initial-unit-evidence')),
      );
      expect(field.decoration, isA<UtenInputDecoration>());
      expect((field.decoration! as UtenInputDecoration).base.error, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'historical quantity preflight explains the block and disables confirmation',
    (tester) async {
      final tasks = _Tasks()
        ..context = const RdInitialUnitContext(
          allowed: false,
          reason: '已有数量事实，不能补历史单位',
        );
      await pump(tester, _Units(), tasks);
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('rd-initial-unit-confirm')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<UtenDropdownField>(
              find.byKey(const Key('rd-initial-unit-choice')),
            )
            .errorMessage,
        contains('数量事实'),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('lookup failure retries in place and retains the dialog', (
    tester,
  ) async {
    final units = _Units()..fail = true;
    await pump(tester, units, _Tasks());
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('rd-initial-unit-confirm')))
          .onPressed,
      isNull,
    );
    units.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(units.calls, 2);
    expect(find.byKey(const Key('rd-initial-unit-choice')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
