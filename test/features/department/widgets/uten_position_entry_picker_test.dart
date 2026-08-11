import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/department/models/position.dart';
import 'package:uten_imp/features/department/models/department_node.dart';
import 'package:uten_imp/features/department/repositories/position_repository.dart';
import 'package:uten_imp/features/department/widgets/uten_position_entry_picker.dart';
import 'package:uten_imp/features/department/widgets/uten_department_picker.dart';

void main() {
  testWidgets('未选部门时岗位字段禁用', (tester) async {
    final repository = _FakePositionRepository();
    await _pumpPicker(
      tester,
      repository: repository,
      departmentId: null,
      onChanged: (_) {},
    );

    expect(find.text('请先选择部门'), findsOneWidget);
    await tester.tap(find.byKey(const Key('uten-position-entry-field')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('uten-position-entry-search')), findsNothing);
    expect(repository.requestedDepartments, isEmpty);
  });

  testWidgets('部门与岗位空字段使用相同高度', (tester) async {
    final repository = _FakePositionRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [positionRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  UtenDepartmentPicker(
                    mode: UtenDepartmentPickerMode.single,
                    label: '部门',
                    treeOverride: [
                      DepartmentNode(
                        id: 'dept-a',
                        code: 'DEPT_A',
                        name: '生产部',
                        level: '一级部门',
                        children: const [],
                      ),
                    ],
                    onChanged: (_) {},
                  ),
                  const SizedBox(height: 12),
                  UtenPositionEntryPicker(
                    departmentId: 'dept-a',
                    label: '岗位',
                    onChanged: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final decorators = find.byType(InputDecorator).evaluate().toList();
    expect(decorators, hasLength(2));
    final departmentHeight =
        (decorators[0].renderObject! as RenderBox).size.height;
    final positionHeight =
        (decorators[1].renderObject! as RenderBox).size.height;
    expect(positionHeight, departmentHeight);
  });

  testWidgets('宽屏使用右侧抽屉且取消或关闭都不回填', (tester) async {
    final repository = _FakePositionRepository();
    var changedCalls = 0;
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpPicker(
      tester,
      repository: repository,
      departmentId: 'dept-a',
      onChanged: (_) => changedCalls++,
    );

    await _openSheet(tester);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SizedBox &&
            widget.width == 420 &&
            widget.height == double.infinity,
      ),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('uten-position-entry-search')),
      '工艺协调员',
    );
    await tester.tap(find.byKey(const Key('uten-position-entry-cancel')));
    await tester.pumpAndSettle();
    expect(changedCalls, 0);

    await _openSheet(tester);
    await tester.enterText(
      find.byKey(const Key('uten-position-entry-search')),
      '新岗位',
    );
    await tester.tap(find.byTooltip('取消'));
    await tester.pumpAndSettle();
    expect(changedCalls, 0);
    expect(find.byKey(const Key('uten-position-entry-search')), findsNothing);
  });

  testWidgets('岗位支持过滤、取消、确认已有项、自定义、清空和部门联动', (tester) async {
    final repository = _FakePositionRepository();
    var departmentId = 'dept-a';
    var value = const PositionEntryValue.empty();
    var changedCalls = 0;

    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [positionRepositoryProvider.overrideWithValue(repository)],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setParentState) => Column(
                children: [
                  UtenPositionEntryPicker(
                    departmentId: departmentId,
                    value: value,
                    label: '岗位',
                    onChanged: (next) {
                      changedCalls++;
                      setParentState(() => value = next);
                    },
                  ),
                  TextButton(
                    key: const Key('change-department'),
                    onPressed: () =>
                        setParentState(() => departmentId = 'dept-b'),
                    child: const Text('切换部门'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    await _openSheet(tester);
    expect(find.byKey(const Key('position-option-assembler')), findsOneWidget);
    expect(find.byKey(const Key('position-option-manager')), findsOneWidget);
    expect(find.byKey(const Key('position-option-quality')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('uten-position-entry-search')),
      '质',
    );
    await tester.pump();
    expect(find.byKey(const Key('position-option-quality')), findsOneWidget);
    expect(find.byKey(const Key('position-option-assembler')), findsNothing);

    await tester.tap(find.byKey(const Key('position-option-quality')));
    await tester.tap(find.byKey(const Key('uten-position-entry-cancel')));
    await tester.pumpAndSettle();
    expect(changedCalls, 0);
    expect(value.isEmpty, isTrue);

    await _openSheet(tester);
    await tester.tap(find.byKey(const Key('position-option-assembler')));
    await tester.tap(find.byKey(const Key('uten-position-entry-confirm')));
    await tester.pumpAndSettle();
    expect(value.position?.id, 'assembler');
    expect(value.customName, isNull);

    await _openSheet(tester);
    await tester.tap(find.byKey(const Key('uten-position-entry-clear')));
    await tester.tap(find.byKey(const Key('uten-position-entry-confirm')));
    await tester.pumpAndSettle();
    expect(value.isEmpty, isTrue);

    await _openSheet(tester);
    await tester.enterText(
      find.byKey(const Key('uten-position-entry-search')),
      '工艺协调员',
    );
    await tester.pump();
    expect(find.byKey(const Key('position-custom-option')), findsOneWidget);
    await tester.tap(find.byKey(const Key('uten-position-entry-confirm')));
    await tester.pumpAndSettle();
    expect(value.position, isNull);
    expect(value.customName, '工艺协调员');

    await tester.tap(find.byKey(const Key('change-department')));
    await tester.pump();
    await tester.pump();
    expect(value.isEmpty, isTrue);
    expect(changedCalls, 4);
    expect(repository.requestedDepartments, everyElement('dept-a'));
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  required PositionRepository repository,
  required String? departmentId,
  required ValueChanged<PositionEntryValue> onChanged,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [positionRepositoryProvider.overrideWithValue(repository)],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: UtenPositionEntryPicker(
            departmentId: departmentId,
            onChanged: onChanged,
          ),
        ),
      ),
    ),
  );
}

Future<void> _openSheet(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('uten-position-entry-field')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('uten-position-entry-search')), findsOneWidget);
}

class _FakePositionRepository implements PositionRepository {
  final requestedDepartments = <String>[];

  static const positions = [
    Position(
      id: 'assembler',
      code: 'POS-ASSEMBLER',
      name: '装配工',
      level: '员工',
      sortOrder: 20,
    ),
    Position(
      id: 'manager',
      code: 'POS-MANAGER',
      name: '车间主任',
      level: '领导层',
      sortOrder: 10,
    ),
    Position(
      id: 'quality',
      code: 'POS-QA',
      name: '质检员',
      level: '员工',
      sortOrder: 30,
    ),
  ];

  @override
  Future<List<Position>> listByDepartment(String deptId) async {
    requestedDepartments.add(deptId);
    return positions;
  }

  @override
  Future<Position> create(String deptId, PositionSaveInput input) =>
      throw UnsupportedError('not used');

  @override
  Future<void> delete(String id) => throw UnsupportedError('not used');

  @override
  Future<Position> update(String id, PositionUpdateInput input) =>
      throw UnsupportedError('not used');
}
