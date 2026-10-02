import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_widgets.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_picker.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_row.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

const _note = PlatformColumnDefinition(
  id: 'note',
  scope: 'resource',
  name: '补充说明',
);
const _hidden = PlatformColumnDefinition(
  id: 'hidden',
  scope: 'resource',
  name: '受保护字段',
  type: 'NUMBER',
  priceProtected: true,
);
const _calculation = PlatformColumnDefinition(
  id: 'calculation',
  scope: 'resource',
  name: '参考计算',
  type: 'CALCULATED',
  formula: PlatformFormula(base: PlatformFormulaOperand(constant: '99')),
);

class _Row extends EditableGridRow {
  _Row([this.id]);
  final String? id;
}

class _MemoryLayout extends PlatformTableLayoutNotifier {
  _MemoryLayout(super.tableKey, this.seed);
  final PlatformTableLayout seed;
  @override
  PlatformTableLayout build() => seed;
  @override
  void persist() {}
}

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  final writes = <Map<String, dynamic>>[];
  final searches = <String>[];
  final creates = <PlatformColumnDefinition>[];
  bool rowWritable = true;
  bool existingWriteAllowed = true;
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => [
    PlatformTableCapabilities(
      scope: 'resource',
      canWrite: existingWriteAllowed,
      canCreate: true,
      canDefine: true,
    ),
  ];
  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async {
    searches.add(query);
    return [_note];
  }

  @override
  Future<PlatformColumnDefinition> create(
    String scope, {
    required String name,
    required String type,
    bool priceProtected = false,
    PlatformFormula? formula,
  }) async {
    final column = PlatformColumnDefinition(
      id: 'created-${creates.length}',
      scope: scope,
      name: name,
      type: type,
      priceProtected: priceProtected,
      formula: formula,
    );
    creates.add(column);
    return column;
  }

  @override
  Future<void> recordUse(String scope, String id) async {}
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async => [
    for (final id in ids)
      PlatformRowValues(
        recordId: id,
        version: 3,
        canWrite: rowWritable && existingWriteAllowed,
        cells: const [
          PlatformColumnCell(columnId: 'note', definition: _note, value: '原记录'),
          PlatformColumnCell(
            columnId: 'hidden',
            definition: _hidden,
            masked: true,
          ),
        ],
      ),
  ];
  @override
  Future<PlatformRowValues> save(
    String scope,
    String recordId, {
    required int expectedVersion,
    required List<Map<String, dynamic>> cells,
  }) async {
    writes.add({
      'scope': scope,
      'recordId': recordId,
      'expectedVersion': expectedVersion,
      'cells': cells,
    });
    return PlatformRowValues(
      recordId: recordId,
      version: 4,
      canWrite: true,
      cells: [
        for (final cell in cells)
          PlatformColumnCell(
            columnId: cell['columnId'] as String,
            definition: cell['columnId'] == 'note' ? _note : _hidden,
            value: cell['value'] as String?,
            masked: cell['columnId'] == 'hidden',
          ),
      ],
    );
  }
}

final _pricePermission = StateProvider<bool>((_) => true);

class _PermissionRepository extends _Repository {
  _PermissionRepository(this.priceVisible);
  final bool priceVisible;
  int reads = 0;
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => [
    PlatformTableCapabilities(
      scope: 'resource',
      canWrite: true,
      canCreate: true,
      priceVisible: priceVisible,
    ),
  ];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async {
    reads++;
    return [for (final id in ids) _permissionRow(id, priceVisible)];
  }
}

PlatformRowValues _permissionRow(String id, bool visible) => PlatformRowValues(
  recordId: id,
  version: 2,
  canWrite: true,
  cells: [
    const PlatformColumnCell(columnId: 'note', definition: _note, value: '原记录'),
    PlatformColumnCell(
      columnId: 'hidden',
      definition: _hidden,
      value: visible ? '350' : null,
      masked: !visible,
    ),
  ],
);

Future<void> _pump(
  WidgetTester tester,
  _Repository repo,
  Widget child, {
  PlatformTableLayout seed = const PlatformTableLayout(),
  TableColumnProjectionController? projection,
}) async {
  await tester.binding.setSurfaceSize(const Size(1100, 850));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final publisher = projection ?? TableColumnProjectionController();
  if (projection == null) addTearDown(publisher.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        platformTableRepositoryProvider.overrideWithValue(repo),
        platformTableLayoutProvider(
          'test.items',
        ).overrideWith(() => _MemoryLayout('test.items', seed)),
      ],
      child: MaterialApp(
        home: TableColumnProjectionScope(
          controller: publisher,
          child: Scaffold(body: ListView(children: [child])),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test(
    'repository capabilities are invalidated for same-user permission changes',
    () {
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(null),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(_pricePermission) ? {'price:view'} : <String>{},
          ),
          apiClientProvider.overrideWithValue(ApiClient(Dio())),
        ],
      );
      addTearDown(container.dispose);
      final before = container.read(platformTableRepositoryProvider);
      container.read(_pricePermission.notifier).state = false;
      expect(
        container.read(platformTableRepositoryProvider),
        isNot(same(before)),
      );
    },
  );
  for (final history in [false, true]) {
    testWidgets(
      'permission revocation masks ${history ? "historical" : "staged"} cells without losing input',
      (tester) async {
        final permitted = _PermissionRepository(true);
        final denied = _PermissionRepository(false);
        final row = _Row('record');
        row.platformFields.adopt(_permissionRow('record', true));
        row.platformFields.setValue(_note, '手填未保存');
        final controller = PlatformTableController<_Row>();
        addTearDown(controller.dispose);
        addTearDown(row.dispose);
        late ProviderContainer container;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              platformTableRepositoryProvider.overrideWith(
                (ref) => ref.watch(_pricePermission) ? permitted : denied,
              ),
              platformTableLayoutProvider('test.items').overrideWith(
                () => _MemoryLayout('test.items', const PlatformTableLayout()),
              ),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  container = ProviderScope.containerOf(context, listen: false);
                  controller.configure(
                    context,
                    columnEditingEnabled: true,
                    descriptor: PlatformTableDescriptor<_Row>(
                      kind: 'master',
                      tableKey: 'test.items',
                      columnKeys: const ['name'],
                      rows: [row],
                    ),
                    explicitBinding: PlatformTableBinding<_Row>(
                      tableKey: 'test.items',
                      scope: 'resource',
                      recordIdOf: (r) => r.id,
                      canEditValues: true,
                      snapshotOf: history
                          ? (r) => _permissionRow(r.id!, true)
                          : null,
                    ),
                    stagedDraftOf: history ? null : (r) => r.platformFields,
                  );
                  return Scaffold(
                    body: TextButton(
                      onPressed: () => showPlatformCellEditor(
                        context,
                        controller,
                        row,
                        _hidden,
                      ),
                      child: const Text('编辑敏感字段'),
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(controller.value(row, _hidden), '350');
        if (!history) {
          await tester.tap(find.text('编辑敏感字段'));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<TextField>(
                  find.byKey(const Key('platform-column-value')),
                )
                .controller!
                .text,
            '350',
          );
        }
        container.read(_pricePermission.notifier).state = false;
        container.read(platformTableRepositoryProvider);
        expect(controller.value(row, _hidden), '***');
        if (!history) expect(row.platformFields.priceVisible, isFalse);
        await tester.pumpAndSettle();
        expect(controller.value(row, _hidden), '***');
        if (!history) {
          expect(find.byKey(const Key('platform-column-value')), findsNothing);
          expect(find.text('当前账号没有查看此字段的权限'), findsOneWidget);
        }
        expect(
          row.platformFields.cells
              .firstWhere((cell) => cell.columnId == 'note')
              .value,
          '手填未保存',
        );
        expect(
          controller.definitions
              .firstWhere((column) => column.id == 'hidden')
              .name,
          '受保护字段',
        );
        if (history) {
          expect(permitted.reads + denied.reads, 0);
          const laterCalculation = PlatformColumnDefinition(
            id: 'later',
            scope: 'resource',
            name: '后来新建',
            type: 'CALCULATED',
            formula: PlatformFormula(
              base: PlatformFormulaOperand(constant: '99'),
            ),
          );
          expect(controller.value(row, laterCalculation), isNull);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'display calculation follows the source text controller immediately',
    (tester) async {
      final qty = TextEditingController(text: '2');
      addTearDown(qty.dispose);
      final row = _Row();
      addTearDown(row.dispose);
      final controller = PlatformTableController<_Row>()
        ..binding = PlatformTableBinding(
          tableKey: 'view',
          scope: 'view_test',
          recordIdOf: (_) => null,
          factValuesOf: (_) => {'qty': qty.text},
          factListenablesOf: (_) => [qty],
        );
      addTearDown(controller.dispose);
      const calculation = PlatformColumnDefinition(
        id: 'double',
        scope: '',
        name: '计算',
        type: 'CALCULATED',
        formula: PlatformFormula(
          base: PlatformFormulaOperand(fact: 'qty'),
          steps: [
            PlatformFormulaStep(
              operation: 'MULTIPLY',
              operand: PlatformFormulaOperand(constant: '2'),
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlatformColumnValue(
              controller: controller,
              row: row,
              column: calculation,
            ),
          ),
        ),
      );
      expect(find.text('4'), findsOneWidget);
      qty.text = '3';
      await tester.pump();
      expect(find.text('6'), findsOneWidget);
      qty.text = '';
      await tester.pump();
      expect(find.text('计算不可用'), findsOneWidget);
    },
  );
  testWidgets(
    'nested toolbar target resolves its own projection among identical schema keys',
    (tester) async {
      final host = TableColumnProjectionController();
      addTearDown(host.dispose);
      final ownerA = Object();
      final ownerB = Object();
      TableColumnProjection? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: TableColumnProjectionScope(
            controller: host,
            child: Builder(
              builder: (context) {
                final route = ModalRoute.of(context);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  host.publish(
                    ownerA,
                    const TableColumnProjection(
                      tableKey: 'same',
                      columns: [
                        TableProjectedColumn(
                          key: 'a',
                          label: 'A',
                          width: 100,
                          type: 'text',
                        ),
                      ],
                    ),
                    contextOwner: route,
                  );
                  host.publish(
                    ownerB,
                    const TableColumnProjection(
                      tableKey: 'same',
                      columns: [
                        TableProjectedColumn(
                          key: 'b',
                          label: 'B',
                          width: 100,
                          type: 'text',
                        ),
                      ],
                    ),
                    contextOwner: route,
                  );
                });
                return TableColumnProjectionTarget(
                  tableKey: 'same',
                  owner: ownerB,
                  child: Builder(
                    builder: (inside) => TextButton(
                      onPressed: () =>
                          selected = TableColumnProjectionScope.resolve(inside),
                      child: const Text('Export'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('Export'));
      expect(selected!.columns.single.key, 'b');
    },
  );

  for (final historical in [false, true]) {
    testWidgets(
      '${historical ? "historical review with explicit opt-in" : "default review"} only restores existing hidden columns for a writable account',
      (tester) async {
        final repo = _Repository();
        final row = _Row('record');
        addTearDown(row.dispose);
        final binding = PlatformTableBinding<_Row>(
          tableKey: 'test.items',
          scope: 'resource',
          recordIdOf: (row) => row.id,
          canEditValues: true,
          snapshotOf: historical ? (_) => _permissionRow('record', true) : null,
        );
        final columns = [
          MasterColumnDef<_Row>(
            key: 'name',
            label: '货品名称',
            width: 180,
            value: (_) => '产品',
          ),
        ];
        // The live review deliberately omits the new option so its safe
        // default is covered even when the account and record allow writes.
        final table = historical
            ? MasterDataTableView<_Row>(
                tableKey: 'test.items',
                columnEditingEnabled: true,
                embedded: true,
                platformBinding: binding,
                columns: columns,
                items: [row],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              )
            : MasterDataTableView<_Row>(
                tableKey: 'test.items',
                embedded: true,
                platformBinding: binding,
                columns: columns,
                items: [row],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
              );
        await _pump(
          tester,
          repo,
          table,
          seed: const PlatformTableLayout(
            order: ['name', 'platform:note', 'platform:hidden'],
            hidden: {'platform:note'},
          ),
        );
        expect(find.text('原记录'), findsNothing);
        expect(find.byIcon(Icons.edit_outlined), findsNothing);
        final displayColumns = find.byKey(
          const Key('platform-table-add-column'),
        );
        expect(tester.widget<IconButton>(displayColumns).tooltip, '显示列');
        await tester.tap(displayColumns);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('platform-column-new')), findsNothing);
        expect(find.byKey(const Key('platform-column-create')), findsNothing);
        expect(find.text('复用已有列'), findsNothing);
        expect(repo.searches, isEmpty);
        await tester.tap(find.text('补充说明'));
        await tester.pumpAndSettle();
        expect(find.text('原记录'), findsOneWidget);
        await tester.tap(find.text('原记录'));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('platform-column-value')), findsNothing);
        expect(repo.writes, isEmpty);
        expect(repo.creates, isEmpty);
      },
    );
  }

  testWidgets('default editable grid does not stage or edit review fields', (
    tester,
  ) async {
    final repo = _Repository();
    final row = _Row();
    final grid = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(grid.dispose);
    await _pump(
      tester,
      repo,
      UtenEditableGrid<_Row>(
        tableKey: 'test.items',
        platformBinding: PlatformTableBinding(
          tableKey: 'test.items',
          scope: 'resource',
          recordIdOf: (row) => row.id,
          canEditValues: true,
        ),
        controller: grid,
        columns: [
          EditableGridColumn(
            key: 'name',
            label: '货品名称',
            width: 180,
            cellBuilder: (_, _) => const Text('产品'),
          ),
        ],
        showAddRow: false,
        showRowDelete: false,
      ),
      seed: const PlatformTableLayout(added: [_note, _calculation]),
    );
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(row.platformFields.savePayload(), isNull);
    final displayColumns = find.byKey(const Key('editable-grid-add-column'));
    expect(tester.widget<IconButton>(displayColumns).tooltip, '显示列');
    repo.searches.clear();
    await tester.tap(displayColumns);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('platform-column-new')), findsNothing);
    expect(repo.searches, isEmpty);
    expect(repo.writes, isEmpty);
  });

  testWidgets('new grid explicitly enables column creation and staged input', (
    tester,
  ) async {
    final repo = _Repository();
    final row = _Row();
    final grid = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(grid.dispose);
    await _pump(
      tester,
      repo,
      UtenEditableGrid<_Row>(
        tableKey: 'test.items',
        columnEditingEnabled: true,
        platformBinding: PlatformTableBinding(
          tableKey: 'test.items',
          scope: 'resource',
          recordIdOf: (row) => row.id,
          canEditValues: true,
        ),
        controller: grid,
        columns: [
          EditableGridColumn(
            key: 'name',
            label: '货品名称',
            width: 180,
            cellBuilder: (_, _) => const Text('新产品'),
          ),
        ],
        showAddRow: false,
        showRowDelete: false,
      ),
    );
    await tester.tap(find.byKey(const Key('editable-grid-add-column')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platform-column-new')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('platform-column-name')),
      '新单据说明',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platform-column-create')));
    await tester.pumpAndSettle();
    expect(repo.creates.single.name, '新单据说明');
    expect(repo.creates.single.type, 'TEXT');
    expect(find.text('新单据说明'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('platform-column-value')),
      '待提交说明',
    );
    await tester.tap(find.byKey(const Key('platform-column-value-save')));
    await tester.pumpAndSettle();
    expect(row.platformFields.savePayload()!['cells'], [
      {'columnId': repo.creates.single.id, 'value': '待提交说明'},
    ]);
    expect(repo.writes, isEmpty);
  });

  testWidgets(
    'switching out of edit mode fences open editors and direct writes',
    (tester) async {
      final repo = _Repository();
      final row = _Row('record');
      addTearDown(row.dispose);
      final editing = ValueNotifier(true);
      addTearDown(editing.dispose);
      final controller = PlatformTableController<_Row>();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        repo,
        ValueListenableBuilder<bool>(
          valueListenable: editing,
          builder: (context, enabled, _) {
            controller.configure(
              context,
              columnEditingEnabled: enabled,
              descriptor: PlatformTableDescriptor<_Row>(
                kind: 'master',
                tableKey: 'test.items',
                columnKeys: const ['name'],
                rows: [row],
              ),
              explicitBinding: PlatformTableBinding<_Row>(
                tableKey: 'test.items',
                scope: 'resource',
                recordIdOf: (row) => row.id,
                canEditValues: true,
              ),
            );
            return TextButton(
              onPressed: () =>
                  showPlatformCellEditor(context, controller, row, _note),
              child: const Text('编辑说明'),
            );
          },
        ),
      );
      expect(controller.canEdit(row, _note), isTrue);
      expect(controller.canDefineColumns, isTrue);
      await tester.tap(find.text('编辑说明'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('platform-column-value')),
        '审核时不能保存',
      );
      editing.value = false;
      await tester.pumpAndSettle();
      expect(controller.columnEditingEnabled, isFalse);
      expect(controller.canDefineColumns, isFalse);
      expect(controller.canEdit(row, _note), isFalse);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('platform-column-value')))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<UtenButton>(
              find.byKey(const Key('platform-column-value-save')),
            )
            .onPressed,
        isNull,
      );
      await expectLater(
        controller.saveCell(row, _note, '绕过界面写入'),
        throwsFormatException,
      );
      expect(() => controller.select(_calculation), throwsFormatException);
      expect(controller.layout.added, isEmpty);
      expect(controller.value(row, _note), '原记录');
      expect(repo.writes, isEmpty);
    },
  );

  testWidgets(
    'master table reads persisted fields and saves a complete CAS payload',
    (tester) async {
      final repo = _Repository();
      final row = _Row('record');
      addTearDown(row.dispose);
      final projection = TableColumnProjectionController();
      addTearDown(projection.dispose);
      await _pump(
        tester,
        repo,
        MasterDataTableView<_Row>(
          tableKey: 'test.items',
          columnEditingEnabled: true,
          embedded: true,
          platformBinding: PlatformTableBinding(
            tableKey: 'test.items',
            scope: 'resource',
            recordIdOf: (row) => row.id,
            canEditValues: true,
          ),
          columns: [
            MasterColumnDef(
              key: 'name',
              label: '货品名称',
              width: 180,
              value: (_) => '产品',
            ),
          ],
          items: [row],
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
        ),
        projection: projection,
      );
      expect(find.text('原记录'), findsOneWidget);
      expect(find.text('***'), findsOneWidget);
      expect(projection.resolve('test.items')!.columns.map((c) => c.key), [
        'name',
        'platform:note',
        'platform:hidden',
      ]);
      await tester.tap(find.text('原记录'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('platform-column-value')),
        '新的说明',
      );
      await tester.tap(find.byKey(const Key('platform-column-value-save')));
      await tester.pumpAndSettle();
      expect(repo.writes.single, {
        'scope': 'resource',
        'recordId': 'record',
        'expectedVersion': 3,
        'cells': [
          {'columnId': 'hidden', 'value': null},
          {'columnId': 'note', 'value': '新的说明'},
        ],
      });
      expect(find.text('新的说明'), findsOneWidget);
    },
  );
  testWidgets('new editable row stages fields in the document without PUT', (
    tester,
  ) async {
    final repo = _Repository()..existingWriteAllowed = false;
    final row = _Row();
    final grid = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(grid.dispose);
    await _pump(
      tester,
      repo,
      UtenEditableGrid<_Row>(
        tableKey: 'test.items',
        columnEditingEnabled: true,
        platformBinding: PlatformTableBinding(
          tableKey: 'test.items',
          scope: 'resource',
          recordIdOf: (row) => row.id,
          canEditValues: true,
        ),
        controller: grid,
        columns: [
          EditableGridColumn(
            key: 'name',
            label: '货品名称',
            width: 180,
            cellBuilder: (_, _) => const Text('新行'),
          ),
        ],
        showAddRow: false,
        showRowDelete: false,
      ),
      seed: const PlatformTableLayout(added: [_note]),
    );
    expect(find.text('补充说明'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('platform-column-value')),
      '随业务保存',
    );
    await tester.tap(find.byKey(const Key('platform-column-value-save')));
    await tester.pumpAndSettle();
    expect(repo.writes, isEmpty);
    expect(platformRowPayload(row), {
      'platformFields': {
        'expectedVersion': 0,
        'cells': [
          {'columnId': 'note', 'value': '随业务保存'},
        ],
      },
    });
    expect(find.text('随业务保存'), findsOneWidget);
  });
  testWidgets('read-only row never gets an edit affordance', (tester) async {
    final repo = _Repository()..rowWritable = false;
    final row = _Row('record');
    addTearDown(row.dispose);
    await _pump(
      tester,
      repo,
      MasterDataTableView<_Row>(
        tableKey: 'test.items',
        columnEditingEnabled: true,
        embedded: true,
        platformBinding: PlatformTableBinding(
          tableKey: 'test.items',
          scope: 'resource',
          recordIdOf: (row) => row.id,
          canEditValues: true,
        ),
        columns: [
          MasterColumnDef(
            key: 'name',
            label: '货品名称',
            width: 180,
            value: (_) => '产品',
          ),
        ],
        items: [row],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
      ),
    );
    expect(find.text('原记录'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsNothing);
    expect(repo.writes, isEmpty);
  });
  for (final existing in [false, true]) {
    testWidgets(
      'selected calculation is captured on ${existing ? "hydrated" : "new"} document rows without PUT',
      (tester) async {
        final repo = _Repository();
        final row = _Row(existing ? 'record' : null);
        final grid = UtenEditableGridController<_Row>(initial: [row]);
        addTearDown(grid.dispose);
        await _pump(
          tester,
          repo,
          UtenEditableGrid<_Row>(
            tableKey: 'test.items',
            columnEditingEnabled: true,
            platformBinding: PlatformTableBinding(
              tableKey: 'test.items',
              scope: 'resource',
              recordIdOf: (row) => row.id,
              canEditValues: true,
            ),
            controller: grid,
            columns: [
              EditableGridColumn(
                key: 'name',
                label: '名称',
                width: 180,
                cellBuilder: (_, _) => const Text('产品'),
              ),
            ],
            showAddRow: false,
            showRowDelete: false,
          ),
          seed: const PlatformTableLayout(added: [_calculation]),
        );
        expect(repo.writes, isEmpty);
        final payload = row.platformFields.savePayload()!;
        expect(payload['expectedVersion'], existing ? 3 : 0);
        expect(payload['sourceRecordId'], existing ? 'record' : null);
        expect(
          payload['cells'],
          contains(equals({'columnId': 'calculation', 'value': null})),
        );
        if (existing) {
          expect(
            payload['cells'],
            contains(equals({'columnId': 'note', 'value': '原记录'})),
          );
          expect(
            payload['cells'],
            contains(equals({'columnId': 'hidden', 'value': null})),
          );
        }
        expect(find.text('99'), findsOneWidget);
      },
    );
  }
}
