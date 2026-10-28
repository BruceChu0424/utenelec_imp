import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/department/models/position.dart';
import 'package:uten_imp/features/department/repositories/position_repository.dart';
import 'package:uten_imp/features/department/widgets/uten_position_picker.dart';

void main() {
  testWidgets('岗位表格保持领导层和组内排序，点行只暂存，确认才回填', (tester) async {
    Position? selected;
    await _pump(tester, onChanged: (value) => selected = value);
    await _open(tester);
    final table = tester.widget<MasterDataTableView<Position>>(
      find.byKey(const Key('position-candidates-table')),
    );
    expect(table.columns.map((column) => column.label), ['岗位名称', '编号', '职级']);
    expect(table.items.map((position) => position.id), [
      'manager',
      'assembler',
      'quality',
    ]);
    await tester.tap(find.byKey(const Key('position-option-assembler')));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(
      tester
          .widget<MasterDataTableView<Position>>(
            find.byKey(const Key('position-candidates-table')),
          )
          .isSelected!(_positions[2]),
      isTrue,
    );
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'assembler');
  });

  testWidgets('岗位表头自定义检索只定位候选，确认后才回填', (tester) async {
    Position? selected;
    await _pump(tester, onChanged: (value) => selected = value);
    await _open(tester);
    await tester.tap(find.text('岗位名称'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '装配',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('position-option-assembler')), findsOneWidget);
    expect(find.byKey(const Key('position-option-manager')), findsNothing);
    expect(selected, isNull);
    await tester.tap(find.byKey(const Key('position-option-assembler')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'assembler');
    expect(tester.takeException(), isNull);
  });

  testWidgets('取消岗位选择不回填', (tester) async {
    var calls = 0;
    await _pump(tester, onChanged: (_) => calls++);
    await _open(tester);
    await tester.tap(find.byKey(const Key('position-option-manager')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('滑窗打开时切换部门，旧岗位确认不会回填新部门', (tester) async {
    var departmentId = 'dept-a';
    var calls = 0;
    late StateSetter updateParent;
    await tester.pumpWidget(
      _app(
        StatefulBuilder(
          builder: (context, setState) {
            updateParent = setState;
            return UtenPositionPicker(
              departmentId: departmentId,
              onChanged: (_) => calls++,
            );
          },
        ),
      ),
    );
    await _open(tester);
    await tester.tap(find.byKey(const Key('position-option-manager')));
    updateParent(() => departmentId = 'dept-b');
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(calls, 0);
  });

  testWidgets('深色小屏放大岗位表格没有溢出且确认可用', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    Position? selected;
    await _pump(
      tester,
      onChanged: (value) => selected = value,
      dark: true,
      textScale: 1.5,
    );
    await _open(tester);
    expect(find.text('岗位名称'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('position-option-manager')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(selected?.id, 'manager');
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pump(
  WidgetTester tester, {
  required ValueChanged<Position?> onChanged,
  bool dark = false,
  double textScale = 1,
}) => tester.pumpWidget(
  _app(
    UtenPositionPicker(departmentId: 'dept-a', onChanged: onChanged),
    dark: dark,
    textScale: textScale,
  ),
);

Widget _app(Widget child, {bool dark = false, double textScale = 1}) =>
    ProviderScope(
      overrides: [positionRepositoryProvider.overrideWithValue(_Repository())],
      child: MaterialApp(
        theme: dark ? ThemeData.dark() : ThemeData.light(),
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: child),
      ),
    );

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byType(InputDecorator));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('position-candidates-table')), findsOneWidget);
}

const _positions = [
  Position(
    id: 'quality',
    code: 'POS-QA',
    name: '质检员',
    level: '员工',
    sortOrder: 30,
  ),
  Position(
    id: 'manager',
    code: 'POS-MANAGER',
    name: '车间主任',
    level: '领导层',
    sortOrder: 10,
  ),
  Position(
    id: 'assembler',
    code: 'POS-ASSEMBLER',
    name: '装配工',
    level: '员工',
    sortOrder: 20,
  ),
];

class _Repository implements PositionRepository {
  @override
  Future<List<Position>> listByDepartment(String deptId) async => _positions;
  @override
  Future<Position> create(String deptId, PositionSaveInput input) =>
      throw UnsupportedError('not used');
  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');
  @override
  Future<Position> update(String id, PositionUpdateInput input) =>
      throw UnsupportedError('not used');
}
