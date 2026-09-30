import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/print/uten_print_preview.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';
import 'package:uten_imp/shared/platform_tables/table_column_projection.dart';

class PrintRepository extends PlatformTableRepository {
  PrintRepository(this.capabilities, this.values, [this.definitions = const []])
    : super(ApiClient(Dio()));
  final List<PlatformColumnDefinition> definitions;
  List<String>? requestedDefinitions;
  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async {
    requestedDefinitions = ids;
    return definitions;
  }

  final PlatformTableCapabilities capabilities;
  final List<PlatformRowValues> values;
  @override
  Future<List<PlatformTableCapabilities>> scopes() async => [capabilities];
  @override
  Future<List<PlatformRowValues>> rows(
    String scope,
    List<String> ids, {
    List<String> columnIds = const [],
  }) async => values;
}

TableProjectedColumn column(
  String key,
  String label, {
  double width = 120,
  Map<String, dynamic>? definition,
}) => TableProjectedColumn(
  key: key,
  label: label,
  width: width,
  type: 'text',
  definition: definition,
);
void main() {
  test(
    'hidden canonical facts use raw source aliases with scientific precision',
    () async {
      const definition = PlatformColumnDefinition(
        id: 'calc',
        scope: 'view_sales',
        name: '小额',
        type: 'CALCULATED',
        formula: PlatformFormula(base: PlatformFormulaOperand(fact: 'amount')),
      );
      final repository = PrintRepository(
        const PlatformTableCapabilities(
          scope: 'view_sales',
          supportsValues: false,
          facts: [PlatformTableFact(key: 'amount', name: '金额')],
        ),
        const [],
        [definition],
      );
      final result = await projectUtenPrintTable(
        const UtenPrintTable(
          headers: ['名称'],
          columnKeys: ['name'],
          rows: [
            ['A'],
          ],
          factValues: [
            {'amountOriginal': '1e-9'},
          ],
        ),
        TableColumnProjection(
          tableKey: 'report',
          scope: 'view_sales',
          sourceKeys: const {'amount': 'amountOriginal'},
          columns: [column('platform:calc', '小额')],
        ),
        repository: repository,
      );
      expect(result.rows, [
        ['0.000000001'],
      ]);
    },
  );
  test(
    'preview and PDF data follow stable visible IDs, current labels, order and widths',
    () async {
      const source = UtenPrintTable(
        headers: ['名称', '隐藏金额', '数量'],
        columnKeys: ['name', 'price', 'qty'],
        rows: [
          ['货品', '99', '3'],
        ],
      );
      final projected = await projectUtenPrintTable(
        source,
        TableColumnProjection(
          tableKey: 'items',
          columns: [
            column('qty', '本次数量', width: 80),
            column('name', '货品名称', width: 260),
          ],
        ),
      );
      expect(projected.headers, ['本次数量', '货品名称']);
      expect(projected.rows, [
        ['3', '货品'],
      ]);
      expect(projected.columnWidths, [80, 260]);
      expect(projected.columnKeys, ['qty', 'name']);
    },
  );
  test('labels never stand in for missing field identity', () async {
    const source = UtenPrintTable(
      headers: ['金额'],
      rows: [
        ['100'],
      ],
    );
    expect(
      () => projectUtenPrintTable(
        source,
        TableColumnProjection(
          tableKey: 'items',
          columns: [column('amount', '金额')],
        ),
      ),
      throwsFormatException,
    );
  });
  test(
    'new entity fields use authorized batch records and keep masked cells masked',
    () async {
      const definition = PlatformColumnDefinition(
        id: 'fee',
        scope: 'master_client',
        name: '扩展字段',
      );
      final repository = PrintRepository(
        const PlatformTableCapabilities(scope: 'master_client'),
        const [
          PlatformRowValues(
            recordId: 'client-1',
            cells: [
              PlatformColumnCell(
                columnId: 'fee',
                value: 'secret',
                definition: definition,
                masked: true,
              ),
            ],
          ),
        ],
      );
      const source = UtenPrintTable(
        headers: ['客户'],
        columnKeys: ['name'],
        rowIds: ['client-1'],
        rows: [
          ['客户甲'],
        ],
      );
      final projected = await projectUtenPrintTable(
        source,
        TableColumnProjection(
          tableKey: 'clients',
          scope: 'master_client',
          columns: [column('name', '客户'), column('platform:fee', '扩展字段')],
        ),
        repository: repository,
      );
      expect(projected.rows, [
        ['客户甲', '***'],
      ]);
    },
  );
  test(
    'report calculations keep hidden dependencies and unformatted authoritative facts',
    () async {
      final dependency = {
        'id': 'hidden',
        'scope': 'view_sales',
        'name': '数量翻倍',
        'type': 'CALCULATED',
        'formula': {
          'base': {'fact': 'qty'},
          'steps': [
            {
              'operation': 'MULTIPLY',
              'operand': {'constant': '2'},
            },
          ],
        },
      };
      final result = {
        'id': 'result',
        'scope': 'view_sales',
        'name': '计算',
        'type': 'CALCULATED',
        'formula': {
          'base': {'columnId': 'hidden'},
          'steps': [
            {
              'operation': 'ADD',
              'operand': {'fact': 'price'},
            },
          ],
        },
        'dependencies': [dependency],
      };
      final repository = PrintRepository(
        const PlatformTableCapabilities(
          scope: 'view_sales',
          supportsValues: false,
          priceVisible: true,
          facts: [
            PlatformTableFact(key: 'qty', name: '数量'),
            PlatformTableFact(key: 'price', name: '单价', priceProtected: true),
          ],
        ),
        const [],
        [
          PlatformColumnDefinition.fromJson(result),
          PlatformColumnDefinition.fromJson(dependency),
        ],
      );
      const source = UtenPrintTable(
        headers: ['数量', '单价'],
        columnKeys: ['qty', 'price'],
        rows: [
          ['3 个', 'CNY 4.00'],
        ],
        factValues: [
          {'qty': '3', 'price': '4'},
        ],
      );
      final projected = await projectUtenPrintTable(
        source,
        TableColumnProjection(
          tableKey: 'report',
          scope: 'view_sales',
          columns: [
            column(
              'platform:result',
              '计算',
              definition: {
                'id': 'result',
                'type': 'CALCULATED',
                'formula': {
                  'base': {'constant': '99999'},
                  'steps': <Map<String, dynamic>>[],
                },
              },
            ),
          ],
        ),
        repository: repository,
      );
      expect(projected.rows, [
        ['10'],
      ]);
      expect(repository.requestedDefinitions, ['result']);
    },
  );
  test(
    'a missing record blocks printing instead of dropping new fields',
    () async {
      final repository = PrintRepository(
        const PlatformTableCapabilities(scope: 'master_client'),
        const [],
      );
      const source = UtenPrintTable(
        headers: ['名称'],
        columnKeys: ['name'],
        rowIds: ['missing'],
        rows: [
          ['客户'],
        ],
      );
      expect(
        () => projectUtenPrintTable(
          source,
          TableColumnProjection(
            tableKey: 'clients',
            scope: 'master_client',
            columns: [column('platform:field', '扩展')],
          ),
          repository: repository,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'report cannot use formatted display text when raw numeric facts are absent',
    () async {
      const definition = PlatformColumnDefinition(
        id: 'calc',
        scope: 'view_sales',
        name: '计算',
        type: 'CALCULATED',
        formula: PlatformFormula(base: PlatformFormulaOperand(fact: 'qty')),
      );
      final repository = PrintRepository(
        const PlatformTableCapabilities(
          scope: 'view_sales',
          supportsValues: false,
          facts: [PlatformTableFact(key: 'qty', name: '数量')],
        ),
        const [],
        [definition],
      );
      const source = UtenPrintTable(
        headers: ['数量'],
        columnKeys: ['qty'],
        rows: [
          ['1,000 万'],
        ],
      );
      expect(
        () => projectUtenPrintTable(
          source,
          TableColumnProjection(
            tableKey: 'report',
            scope: 'view_sales',
            columns: [column('platform:calc', '计算')],
          ),
          repository: repository,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'fact-level financial protection survives an unmarked cached definition',
    () async {
      const definition = PlatformColumnDefinition(
        id: 'calc',
        scope: 'view_sales',
        name: '计算',
        type: 'CALCULATED',
        formula: PlatformFormula(base: PlatformFormulaOperand(fact: 'price')),
      );
      final repository = PrintRepository(
        const PlatformTableCapabilities(
          scope: 'view_sales',
          supportsValues: false,
          facts: [
            PlatformTableFact(key: 'price', name: '单价', priceProtected: true),
          ],
        ),
        const [],
        [definition],
      );
      const source = UtenPrintTable(
        headers: ['名称'],
        columnKeys: ['name'],
        rows: [
          ['A'],
        ],
        factValues: [
          {'price': '999'},
        ],
      );
      expect(
        () => projectUtenPrintTable(
          source,
          TableColumnProjection(
            tableKey: 'report',
            scope: 'view_sales',
            columns: [column('platform:calc', '计算')],
          ),
          repository: repository,
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'canonical projection IDs keep original loader keys and hidden fact aliases',
    () async {
      const source = UtenPrintTable(
        headers: ['原币金额', '名称'],
        columnKeys: ['amountOriginal', 'goodsName'],
        rows: [
          ['4.00', '货品'],
        ],
        factValues: [
          {'amountOriginal': '4'},
        ],
      );
      const projection = TableColumnProjection(
        tableKey: 'report',
        sourceKeys: {'amount': 'amountOriginal', 'goods': 'goodsName'},
        columns: [
          TableProjectedColumn(
            key: 'goods',
            sourceKey: 'goodsName',
            label: '货品',
            width: 100,
            type: 'text',
          ),
          TableProjectedColumn(
            key: 'amount',
            sourceKey: 'amountOriginal',
            label: '金额',
            width: 120,
            type: 'money',
          ),
        ],
      );
      final result = await projectUtenPrintTable(source, projection);
      expect(result.rows, [
        ['货品', '4.00'],
      ]);
      expect(projection.toJson().toString(), isNot(contains('sourceKey')));
    },
  );
}
