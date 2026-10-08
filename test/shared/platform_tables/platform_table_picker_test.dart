import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_picker.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_repository.dart';

const _note = PlatformColumnDefinition(
  id: 'note',
  scope: 'resource',
  name: '包装说明',
);
const _number = PlatformColumnDefinition(
  id: 'number',
  scope: 'resource',
  name: '参考数量',
  type: 'NUMBER',
);
const _facts = [PlatformTableFact(key: 'quantity', name: '数量')];
const _capabilities = PlatformTableCapabilities(
  scope: 'resource',
  canWrite: true,
  canDefine: true,
  facts: _facts,
);

class _Repository extends PlatformTableRepository {
  _Repository() : super(ApiClient(Dio()));
  bool failSearch = false;
  int creates = 0;
  PlatformColumnDefinition? created;
  Completer<void>? createGate;
  Completer<void>? searchGate;
  final queries = <String>[];

  @override
  Future<List<PlatformColumnDefinition>> search(
    String scope,
    String query, {
    List<String>? ids,
  }) async {
    queries.add(query);
    await searchGate?.future;
    if (failSearch) throw const FormatException('列目录暂时不可用');
    return [
      _note,
      _number,
    ].where((column) => column.name.contains(query)).toList();
  }

  @override
  Future<PlatformColumnDefinition> create(
    String scope, {
    required String name,
    required String type,
    bool priceProtected = false,
    PlatformFormula? formula,
  }) async {
    creates++;
    await createGate?.future;
    return created = PlatformColumnDefinition(
      id: 'created',
      scope: scope,
      name: name,
      type: type,
      formula: formula,
    );
  }
}

class _Controller extends PlatformTableController<String> {
  _Controller(
    _Repository repo, {
    bool bound = true,
    required this.columnEditingEnabled,
  }) {
    repository = bound ? repo : null;
    capabilities = bound ? _capabilities : null;
    binding = bound
        ? PlatformTableBinding<String>(
            tableKey: 'test.items',
            scope: 'resource',
            recordIdOf: (row) => row,
            canEditValues: true,
          )
        : null;
  }
  @override
  bool columnEditingEnabled;
  PlatformColumnDefinition? selected;
  bool priceMasked = false;
  bool writable = true;
  bool failSave = false;
  String? saved;
  int reloads = 0;

  @override
  bool canCalculateFact(String key) => key == 'quantity';
  @override
  void select(PlatformColumnDefinition column) => selected = column;
  @override
  Future<void> reload() async {
    reloads++;
    error = null;
  }

  @override
  bool masked(String item, PlatformColumnDefinition column) => priceMasked;
  @override
  bool canEdit(String item, PlatformColumnDefinition column) =>
      writable && !priceMasked;
  @override
  String? value(
    String item,
    PlatformColumnDefinition column, [
    Set<String> visiting = const {},
  ]) => '12';
  @override
  Future<void> saveCell(
    String item,
    PlatformColumnDefinition column,
    String? value,
  ) async {
    if (failSave) throw const FormatException('记录已变化，请重新读取后再保存');
    saved = value;
  }

  void changeFacts(List<PlatformTableFact> facts) {
    capabilities = PlatformTableCapabilities(
      scope: 'resource',
      canWrite: true,
      canDefine: true,
      facts: facts,
    );
    notifyListeners();
  }

  void switchRepository(_Repository next) {
    repository = next;
    notifyListeners();
  }

  void switchEditingMode(bool enabled) {
    columnEditingEnabled = enabled;
    notifyListeners();
  }
}

Future<void> _open(
  WidgetTester tester,
  _Controller controller, {
  Size size = const Size(900, 850),
  double scale = 1,
  double keyboard = 0,
  bool dark = false,
  bool cell = false,
  bool settle = true,
  ValueChanged<String?>? onResult,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? buildDarkTheme() : buildLightTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              if (cell) {
                await showPlatformCellEditor(
                  context,
                  controller,
                  'row',
                  _number,
                );
              } else {
                final result = await showPlatformColumnPicker(
                  context,
                  controller: controller,
                  hiddenColumns: const [
                    PlatformSystemColumn(key: 'note', label: '备注'),
                  ],
                  allColumns: const [
                    PlatformSystemColumn(
                      key: 'quantity',
                      label: '数量',
                      numeric: true,
                    ),
                  ],
                );
                onResult?.call(result);
              }
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _choose(WidgetTester tester, String key, String label) async {
  await _tap(tester, find.byKey(Key(key)));
  await _tap(tester, find.text(label).last);
}

Future<void> _newFormula(WidgetTester tester) async {
  await _tap(tester, find.byKey(const Key('platform-column-new')));
  await tester.enterText(find.byKey(const Key('platform-column-name')), '参考合计');
  await tester.pumpAndSettle();
  await _choose(tester, 'platform-column-type', '自动计算');
  await _choose(tester, 'platform-formula-base', '数量');
}

void main() {
  testWidgets(
    'pending catalog search recovers after switching to review and back to creation',
    (tester) async {
      final repository = _Repository()..searchGate = Completer<void>();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller, settle: false);
      expect(repository.queries, ['']);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      controller.switchEditingMode(false);
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byKey(const Key('platform-column-new')), findsNothing);
      expect(find.text('包装说明'), findsNothing);
      expect(find.text('备注'), findsOneWidget);

      repository.searchGate!.complete();
      repository.searchGate = null;
      await tester.pumpAndSettle();
      expect(find.text('包装说明'), findsNothing);
      expect(repository.queries, ['']);

      controller.switchEditingMode(true);
      await tester.pumpAndSettle();
      expect(repository.queries, ['', '']);
      expect(find.text('包装说明'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await _tap(tester, find.byKey(const Key('platform-column-new')));
      await tester.enterText(
        find.byKey(const Key('platform-column-name')),
        '恢复创建说明',
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.creates, 1);
      expect(controller.selected?.name, '恢复创建说明');
    },
  );

  testWidgets('an old create failure cannot stop the new account request', (
    tester,
  ) async {
    final first = _Repository()..createGate = Completer<void>();
    final second = _Repository()..createGate = Completer<void>();
    final controller = _Controller(first, columnEditingEnabled: true);
    await _open(tester, controller);
    await _tap(tester, find.byKey(const Key('platform-column-new')));
    await tester.enterText(
      find.byKey(const Key('platform-column-name')),
      '新说明',
    );
    await tester.tap(find.byKey(const Key('platform-column-create')));
    await tester.pump();
    controller.switchRepository(second);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('platform-column-create')));
    await tester.pump();
    first.createGate!.completeError(const FormatException('旧账号创建失败'));
    await tester.pump();
    expect(
      tester
          .widget<UtenButton>(find.byKey(const Key('platform-column-create')))
          .isLoading,
      isTrue,
    );
    expect(find.text('旧账号创建失败'), findsNothing);
    second.createGate!.complete();
    await tester.pumpAndSettle();
    expect(controller.selected, same(second.created));
    expect(first.creates, 1);
    expect(second.creates, 1);
  });

  testWidgets(
    'column limit is checked before creation and points to the actual reset action',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      controller.layout = PlatformTableLayout(
        added: [
          for (var index = 0; index < 32; index++)
            PlatformColumnDefinition(
              id: 'used-$index',
              scope: 'resource',
              name: '已有列 $index',
            ),
        ],
      );
      await _open(tester, controller);
      await _tap(tester, find.byKey(const Key('platform-column-new')));
      await tester.enterText(
        find.byKey(const Key('platform-column-name')),
        '新说明',
      );
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.creates, 0);
      expect(find.textContaining('在表头设置中恢复默认布局'), findsOneWidget);
    },
  );

  testWidgets(
    'in-flight creation blocks barrier and back dismissal until one result is selected',
    (tester) async {
      final repository = _Repository()..createGate = Completer<void>();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await _tap(tester, find.byKey(const Key('platform-column-new')));
      await tester.enterText(
        find.byKey(const Key('platform-column-name')),
        '新说明',
      );
      await tester.tap(find.byKey(const Key('platform-column-create')));
      await tester.pump();
      expect(repository.creates, 1);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tapAt(const Offset(4, 4));
      await tester.pump();
      expect(find.byType(Dialog), findsOneWidget);
      repository.createGate!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
      expect(controller.selected?.id, 'created');
      expect(repository.creates, 1);
    },
  );

  testWidgets(
    'catalog search and existing headers do not create a definition',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      String? result;
      await _open(tester, controller, onResult: (value) => result = value);
      expect(find.byType(UtenSearchBar), findsOneWidget);
      expect(find.byKey(const Key('platform-column-name')), findsNothing);
      await _tap(tester, find.text('备注'));
      expect(result, 'note');
      expect(repository.creates, 0);
    },
  );

  testWidgets(
    'search results reuse existing identity and carry the original field type',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await tester.enterText(
        find.descendant(
          of: find.byType(UtenSearchBar),
          matching: find.byType(TextField),
        ),
        '包装',
      );
      await tester.pumpAndSettle();
      await _tap(tester, find.text('包装说明'));
      expect(controller.selected, same(_note));
      expect(repository.creates, 0);
    },
  );

  testWidgets(
    'new record fields reveal type after name and save without a formula',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await _tap(tester, find.byKey(const Key('platform-column-new')));
      expect(find.byKey(const Key('platform-column-type')), findsNothing);
      await tester.enterText(
        find.byKey(const Key('platform-column-name')),
        '包数',
      );
      await tester.pumpAndSettle();
      await _choose(tester, 'platform-column-type', '记数字');
      expect(find.byKey(const Key('platform-formula-base')), findsNothing);
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.created?.type, 'NUMBER');
      expect(repository.created?.formula, isNull);
      expect(repository.created?.name, '包数');
    },
  );

  testWidgets(
    'formula rejects zero divisor inline and recovers with exact decimal operands',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await _newFormula(tester);
      await _choose(tester, 'platform-formula-operation-0', '除 ÷');
      await tester.enterText(
        find.byKey(const Key('platform-formula-number-0')),
        '-0.00',
      );
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.creates, 0);
      expect(find.text('除数不能为 0'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('platform-formula-number-0')),
        '.5',
      );
      await tester.pumpAndSettle();
      expect(find.text('除数不能为 0'), findsNothing);
      expect(find.textContaining('参考合计 = (数量 ÷ 0.5)'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.created?.formula?.base.fact, 'quantity');
      expect(repository.created?.formula?.steps.single.operand.constant, '0.5');
    },
  );

  testWidgets(
    'formula preview uses ordered parentheses and column references hide constant input',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await _newFormula(tester);
      await tester.enterText(
        find.byKey(const Key('platform-formula-number-0')),
        '10',
      );
      await _tap(tester, find.byKey(const Key('platform-formula-add-step')));
      await _choose(tester, 'platform-formula-operation-1', '乘 ×');
      await _choose(tester, 'platform-formula-source-1', '参考数量');
      expect(find.byKey(const Key('platform-formula-number-1')), findsNothing);
      expect(find.textContaining('参考合计 = ((数量 + 10) × 参考数量)'), findsOneWidget);
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.created?.formula?.steps.map((step) => step.operation), [
        'ADD',
        'MULTIPLY',
      ]);
      expect(
        repository.created?.formula?.steps.last.operand.columnId,
        'number',
      );
    },
  );

  testWidgets(
    'revoked formula source cannot be submitted and asks for another base',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      await _newFormula(tester);
      await tester.enterText(
        find.byKey(const Key('platform-formula-number-0')),
        '10',
      );
      controller.changeFacts(const []);
      await tester.pumpAndSettle();
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.creates, 0);
      expect(find.text('所选数字列已不可用，请重新选择'), findsOneWidget);
      await _choose(tester, 'platform-formula-base', '参考数量');
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(repository.created?.formula?.base.columnId, 'number');
    },
  );

  testWidgets(
    'personal calculations retain local identity without catalog writes',
    (tester) async {
      final repository = _Repository();
      final controller = _Controller(
        repository,
        bound: false,
        columnEditingEnabled: true,
      );
      await _open(tester, controller);
      await _tap(tester, find.byKey(const Key('platform-column-new')));
      await tester.enterText(
        find.byKey(const Key('platform-column-name')),
        '个人参考',
      );
      await tester.pumpAndSettle();
      await _choose(tester, 'platform-formula-base', '数量');
      await tester.enterText(
        find.byKey(const Key('platform-formula-number-0')),
        '5',
      );
      await _tap(tester, find.byKey(const Key('platform-column-create')));
      expect(controller.selected?.id, startsWith('display-'));
      expect(controller.selected?.scope, '');
      expect(controller.selected?.type, 'CALCULATED');
      expect(repository.creates, 0);
    },
  );

  testWidgets(
    'catalog retry retains search and does not replace the new-column form',
    (tester) async {
      final repository = _Repository()..failSearch = true;
      final controller = _Controller(repository, columnEditingEnabled: true);
      await _open(tester, controller);
      expect(find.text('列目录暂时不可用'), findsOneWidget);
      repository.failSearch = false;
      await _tap(tester, find.text('重新加载'));
      expect(find.text('包装说明'), findsOneWidget);
      expect(repository.creates, 0);
    },
  );

  testWidgets('cell validation and conflict recovery preserve typed input', (
    tester,
  ) async {
    final repository = _Repository();
    final controller = _Controller(repository, columnEditingEnabled: true);
    await _open(tester, controller, cell: true);
    final value = find.byKey(const Key('platform-column-value'));
    await tester.enterText(value, 'wrong');
    await _tap(tester, find.byKey(const Key('platform-column-value-save')));
    expect(controller.saved, isNull);
    expect(find.text('请输入有效数字，例如 10、0.5 或 -2'), findsOneWidget);
    expect(find.text('重新读取记录（保留当前输入）'), findsNothing);
    controller.failSave = true;
    await tester.enterText(value, '18.50');
    await _tap(tester, find.byKey(const Key('platform-column-value-save')));
    expect(find.text('记录已变化，请重新读取后再保存'), findsOneWidget);
    await _tap(tester, find.text('重新读取记录（保留当前输入）'));
    expect(tester.widget<TextField>(value).controller?.text, '18.50');
    expect(controller.reloads, 1);
    controller.failSave = false;
    await _tap(tester, find.byKey(const Key('platform-column-value-save')));
    expect(controller.saved, '18.50');
  });

  for (final dark in [false, true]) {
    testWidgets(
      'narrow ${dark ? "dark" : "light"} picker keeps formula and actions usable with keyboard and scaling',
      (tester) async {
        final repository = _Repository();
        final controller = _Controller(repository, columnEditingEnabled: true);
        await _open(
          tester,
          controller,
          size: const Size(360, 780),
          scale: 1.5,
          keyboard: 240,
          dark: dark,
        );
        await _newFormula(tester);
        await tester.ensureVisible(
          find.byKey(const Key('platform-formula-number-0')),
        );
        await tester.enterText(
          find.byKey(const Key('platform-formula-number-0')),
          '12.25',
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final create = find.byKey(const Key('platform-column-create'));
        expect(tester.widget<UtenButton>(create).onPressed, isNotNull);
        expect(tester.getBottomRight(create).dy, lessThanOrEqualTo(540));
        await _tap(tester, create);
        expect(
          repository.created?.formula?.steps.single.operand.constant,
          '12.25',
        );
      },
    );
  }
}
