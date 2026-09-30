import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/shared/platform_tables/platform_row_draft.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_row.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

const note = PlatformColumnDefinition(
  id: 'note',
  scope: 'resource',
  name: '说明',
);
const secret = PlatformColumnDefinition(
  id: 'secret',
  scope: 'resource',
  name: '成本',
  type: 'NUMBER',
  priceProtected: true,
);
const display = PlatformColumnDefinition(
  id: 'display',
  scope: 'resource',
  name: '计算',
  type: 'CALCULATED',
);

class _Row extends EditableGridRow {}

void main() {
  test(
    'raw scientific facts expand exactly without accepting unbounded values',
    () {
      expect(platformExactFact(1e-9), '0.000000001');
      expect(platformExactFact('1e+20'), '100000000000000000000');
      expect(platformExactFact('-1.250e-3'), '-0.00125');
      expect(platformExactFact('1e+40'), isNull);
      expect(platformExactFact('1e-31'), isNull);
      expect(platformExactFact('1e99999999999999'), isNull);
      expect(platformExactFact(double.nan), isNull);
      expect(platformExactFact(double.infinity), isNull);
    },
  );

  test('display arithmetic preserves negatives, order and missing facts', () {
    const formula = PlatformFormula(
      base: PlatformFormulaOperand(fact: 'qty'),
      steps: [
        PlatformFormulaStep(
          operation: 'SUBTRACT',
          operand: PlatformFormulaOperand(constant: '5'),
        ),
        PlatformFormulaStep(
          operation: 'MULTIPLY',
          operand: PlatformFormulaOperand(constant: '2'),
        ),
      ],
    );
    expect(
      formula.calculate(
        (value) => value.constant ?? (value.fact == 'qty' ? '3' : null),
      ),
      '-4',
    );
    expect(formula.calculate((value) => value.constant), isNull);
    const incomplete = PlatformFormula(
      base: PlatformFormulaOperand(constant: '4'),
      steps: [
        PlatformFormulaStep(
          operation: 'ADD',
          operand: PlatformFormulaOperand(fact: 'missing'),
        ),
      ],
    );
    expect(incomplete.calculate((value) => value.constant), isNull);
    const inexact = PlatformFormula(
      base: PlatformFormulaOperand(constant: '1'),
      steps: [
        PlatformFormulaStep(
          operation: 'DIVIDE',
          operand: PlatformFormulaOperand(constant: '3'),
        ),
      ],
    );
    expect(inexact.calculate((value) => value.constant), isNull);
  });
  test(
    'draft edits survive late reads; payload excludes selected empty projections',
    () {
      final draft = PlatformRowDraft();
      draft.adopt(
        const PlatformRowValues(
          recordId: 'record',
          version: 3,
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'secret',
              definition: secret,
              masked: true,
            ),
            PlatformColumnCell(
              columnId: 'display',
              definition: display,
              persisted: false,
            ),
          ],
        ),
      );
      draft.setValue(note, '手工输入');
      draft.adopt(
        const PlatformRowValues(recordId: 'record', version: 2, canWrite: true),
      );
      expect(
        draft.snapshot.cells.firstWhere((c) => c.columnId == 'note').value,
        '手工输入',
      );
      expect(draft.savePayload(), {
        'sourceRecordId': 'record',
        'expectedVersion': 3,
        'cells': [
          {'columnId': 'secret', 'value': null},
          {'columnId': 'note', 'value': '手工输入'},
        ],
      });
      final restored = PlatformRowDraft()..restoreDraft(draft.exportDraft());
      expect(restored.savePayload(), draft.savePayload());
      draft.dispose();
      restored.dispose();
    },
  );
  test('common grid clone retains values with a new metadata identity', () {
    final row = _Row()
      ..platformFields.adopt(
        const PlatformRowValues(
          recordId: 'old',
          version: 7,
          canWrite: true,
          cells: [
            PlatformColumnCell(
              columnId: 'note',
              definition: note,
              value: 'copy me',
            ),
          ],
        ),
      );
    final grid = UtenEditableGridController<_Row>(initial: [row]);
    var updates = 0;
    grid.addListener(() => updates++);
    row.platformFields.setValue(note, 'updated');
    expect(updates, 1);
    grid.setSelected([row], true);
    grid.copySelected((_) => _Row());
    grid.paste((_) => _Row());
    expect(grid.rows.last.platformFields.sourceRecordId, isNull);
    expect(platformRowPayload(grid.rows.last), {
      'platformFields': {
        'expectedVersion': 0,
        'cells': [
          {'columnId': 'note', 'value': 'updated'},
        ],
      },
    });
    grid.dispose();
  });
  test(
    'canonical profiles map edit and review IDs without losing hidden columns',
    () {
      final controller = PlatformTableController<Object>()
        ..binding = PlatformTableBinding(
          tableKey: 'sales.order.items',
          scope: 'view_sales',
          recordIdOf: (_) => null,
          columnAliases: const {'unitName': 'unit', 'listPrice': 'price'},
          defaultVisibleColumnKeys: const ['goods', 'qty', 'unit', 'price'],
          defaultColumnOrder: const ['goods', 'qty', 'unit', 'price'],
        );
      final initial = controller.localLayout([
        'goods',
        'listPrice',
        'unitName',
        'qty',
        'status',
      ], defaultHidden: {});
      expect(initial.order, [
        'goods',
        'qty',
        'unitName',
        'listPrice',
        'status',
      ]);
      expect(initial.hidden, {'status'});
      controller.saveLayout(
        knownKeys: ['goods', 'listPrice', 'unitName', 'qty'],
        order: ['goods', 'qty', 'unitName', 'listPrice'],
        hidden: {'listPrice'},
        pinned: {'goods'},
        widths: {'listPrice': 222},
      );
      final edit = controller.localLayout([
        'goods',
        'qty',
        'unit',
        'price',
      ], defaultHidden: {});
      expect(edit.hidden, {'price'});
      expect(edit.widths['price'], 222);
      expect(PlatformTableLayout.fromJson(controller.layout.toJson()).order, [
        'goods',
        'qty',
        'unit',
        'price',
      ]);
      controller.dispose();
    },
  );
  test(
    'projection resolves the page route before same-key background pages',
    () {
      final controller = TableColumnProjectionController();
      final page1 = Object();
      final page2 = Object();
      const first = TableColumnProjection(
        tableKey: 'items',
        columns: [
          TableProjectedColumn(
            key: 'qty',
            label: '数量',
            width: 123,
            type: 'number',
          ),
        ],
      );
      const second = TableColumnProjection(
        tableKey: 'items',
        columns: [
          TableProjectedColumn(
            key: 'note',
            label: '备注',
            width: 200,
            type: 'text',
          ),
        ],
      );
      controller.publish('a', first, contextOwner: page1);
      controller.publish('b', second, contextOwner: page2);
      expect(controller.resolve('items'), isNull);
      expect(controller.resolve('items', Object()), isNull);
      expect(controller.hasTablesFor(Object()), isFalse);
      expect(controller.resolve('items', page1), same(first));
      expect(controller.resolve('items', page2), same(second));
      expect(first.toJson()['columns'], [
        {'key': 'qty', 'label': '数量', 'width': 123.0, 'type': 'number'},
      ]);
      controller.dispose();
    },
  );
}
