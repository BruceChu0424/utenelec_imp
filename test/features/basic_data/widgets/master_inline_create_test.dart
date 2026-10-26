import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/components/inputs/uten_inline_edit_cell.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_edit_dialog.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';

const _name = MasterFieldDef(key: 'name', label: 'Name', required: true);
const _amount = MasterFieldDef(
  key: 'amount',
  label: 'Amount',
  type: MasterFieldType.money,
);

MasterInlineEditController<String> _controller({
  List<MasterFieldDef> fields = const [_name, _amount],
  Map<String, dynamic> defaults = const {'status': '使用'},
  bool canCreate = true,
  Future<void> Function()? afterSave,
  required Future<void> Function(String, Map<String, dynamic>) create,
}) => MasterInlineEditController<String>()
  ..configureCreation(
    MasterInlineCreateConfig(
      namespace: 'test-records',
      fields: fields,
      defaults: defaults,
      canCreate: canCreate,
      onCreate: create,
      afterSave: afterSave,
    ),
  )
  ..begin();

Future<void> _table(
  WidgetTester tester,
  MasterInlineEditController<String> controller, {
  bool selectable = false,
  List<String> items = const [],
  Map<String, String?> filters = const {},
  Future<void> Function(int)? onPageChange,
  VoidCallback? onLoadMore,
  List<MasterColumnDef<String>> extraColumns = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: MasterDataTableView<String>(
          columns: [
            MasterColumnDef(
              key: 'name',
              label: 'Name',
              width: 220,
              value: (row) => row,
            ),
            MasterColumnDef(
              key: 'amount',
              label: 'Amount',
              width: 180,
              value: (_) => '1.00',
            ),
            ...extraColumns,
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: filters,
          onFilterChanged: (_, _) {},
          onPageChange: onPageChange,
          totalPages: 3,
          onLoadMore: onLoadMore,
          appendRowsSource: controller.appendRowsSource,
          selectable: selectable,
          idOf: (row) => row,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _discardUpdate(String _, Map<String, dynamic> _) async {}

Future<void> _activateCreation(
  WidgetTester tester,
  String key,
  String field,
) async {
  final input = find
      .byKey(ValueKey('inline-create-cell-$key-$field'))
      .hitTestable();
  if (input.evaluate().isNotEmpty) return;
  final activate = find
      .byKey(ValueKey('inline-create-activate-$key-$field'))
      .hitTestable();
  await tester.tap(activate);
  await tester.pump();
}

void main() {
  testWidgets(
    'new rows defer choice requests and the first character does not rebuild sibling editors',
    (tester) async {
      var loads = 0, builds = 0;
      final controller = _controller(
        fields: [
          _name,
          MasterFieldDef(
            key: 'choice',
            label: 'Choice',
            type: MasterFieldType.custom,
            customBuilder: (field) {
              builds++;
              return MasterInlineOptionsCell(
                field: field,
                load: () async {
                  loads++;
                  return const [MasterSelectOption(value: 'one', label: 'One')];
                },
              );
            },
          ),
        ],
        create: (_, _) async {},
      );
      addTearDown(controller.dispose);
      final row = controller.appendRows.first;
      final key = controller.creationDraftKeys.first;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  for (final field in ['name', 'choice'])
                    SizedBox(
                      width: 260,
                      child: row.cellBuilder(context, field),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 0);
      expect(builds, 0);
      expect(find.byType(TextField), findsNothing);
      await _activateCreation(tester, key, 'choice');
      await tester.pumpAndSettle();
      expect(loads, 1);
      final mountedBuilds = builds;
      await _activateCreation(tester, key, 'name');
      final name = find.byKey(ValueKey('inline-create-cell-$key-name'));
      await tester.enterText(name, 'F');
      await tester.pump();
      expect(
        builds,
        mountedBuilds,
        reason:
            'The clean-to-dirty transition only affects the edited field and toolbar',
      );
      await tester.enterText(name, 'First entry');
      await tester.pump();
      expect(builds, mountedBuilds);
      expect(loads, 1);
      expect(controller.creationValuesFor(key)['name'], 'First entry');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'frozen and ordinary editor copies share one creation draft after horizontal scrolling',
    (tester) async {
      final controller = _controller(create: (_, _) async {});
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 600,
              height: 400,
              child: MasterDataTableView<String>(
                requiredLeadingColumnKeys: const ['name'],
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: 'Name',
                    width: 220,
                    value: (row) => row,
                  ),
                  MasterColumnDef(
                    key: 'amount',
                    label: 'Amount',
                    width: 400,
                    value: (_) => '',
                  ),
                  MasterColumnDef(
                    key: 'other',
                    label: 'Other',
                    width: 400,
                    value: (_) => '',
                  ),
                ],
                items: const [],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                appendRowsSource: controller.appendRowsSource,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final key = controller.creationDraftKeys.first;
      Finder input() =>
          find.byKey(ValueKey('inline-create-cell-$key-name')).hitTestable();
      await _activateCreation(tester, key, 'name');
      await tester.enterText(input(), 'Original draft');
      await tester.pumpAndSettle();
      void horizontal(double offset) {
        for (final scroll in tester.widgetList<SingleChildScrollView>(
          find.byType(SingleChildScrollView),
        )) {
          final control = scroll.controller;
          if (scroll.scrollDirection == Axis.horizontal &&
              control?.hasClients == true) {
            control!.jumpTo(offset.clamp(0, control.position.maxScrollExtent));
          }
        }
      }

      horizontal(300);
      await tester.pumpAndSettle();
      await _activateCreation(tester, key, 'name');
      await tester.enterText(input(), 'Edited in frozen column');
      await tester.pumpAndSettle();
      expect(
        controller.creationValuesFor(key)['name'],
        'Edited in frozen column',
      );
      horizontal(0);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(input()).controller!.text,
        'Edited in frozen column',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'discarding an uncertain creation explains the server result truthfully',
    (tester) async {
      final controller = _controller(
        create: (_, _) async => throw NetworkTimeoutException(),
      );
      addTearDown(controller.dispose);
      controller.setCreationValue(
        controller.creationDraftKeys.first,
        'name',
        'Unconfirmed',
      );
      expect(await controller.save(_discardUpdate), isFalse);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => controller.confirmLeave(
                  context,
                  discardNote: 'This must not imply no server writes',
                ),
                child: const Text('Leave'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Leave'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('does not undo server records'),
        findsOneWidget,
      );
      expect(find.text('This must not imply no server writes'), findsNothing);
      await tester.tap(find.text('Discard changes'));
      await tester.pumpAndSettle();
      expect(controller.dirty, isFalse);
      expect(controller.active, isFalse);
    },
  );
  testWidgets('confirmed creations are retired before a failed batch refresh', (
    tester,
  ) async {
    var creates = 0, refreshes = 0;
    late MasterInlineEditController<String> controller;
    controller = _controller(
      create: (_, _) async => creates++,
      afterSave: () async {
        refreshes++;
        expect(
          controller.dirty,
          isFalse,
          reason: 'acknowledgements retire drafts before refreshing',
        );
        throw NetworkTimeoutException();
      },
    );
    addTearDown(controller.dispose);
    final first = controller.creationDraftKeys.first;
    controller.setCreationValue(first, 'name', 'Confirmed one');
    final second = controller.creationDraftKeys[1];
    controller.setCreationValue(second, 'name', 'Confirmed two');
    expect(await controller.save(_discardUpdate), isFalse);
    expect(creates, 2);
    expect(refreshes, 1);
    expect(controller.dirty, isFalse);
    expect(controller.creationDraftKeys, isNot(contains(first)));
    expect(controller.creationDraftKeys, isNot(contains(second)));
    expect(controller.error, contains('资料已保存'));
    expect(await controller.save(_discardUpdate), isFalse);
    expect(creates, 2);
  });

  testWidgets(
    'create-only columns fit editors while existing cells remain read-only',
    (tester) async {
      final controller = _controller(create: (_, _) async {});
      addTearDown(controller.dispose);
      final columns = controller.columns(
        columns: [
          MasterColumnDef<String>(
            key: 'name',
            label: 'Name',
            width: 64,
            value: (value) => value,
            cellBuilder: (_, value) => Text('Read only: $value'),
          ),
        ],
        idOf: (value) => value,
        fields: const {},
      );
      expect(columns.single.width, greaterThanOrEqualTo(140));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  columns.single.cellBuilder!(context, 'Existing'),
            ),
          ),
        ),
      );
      expect(find.text('Read only: Existing'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
    },
  );
  testWidgets(
    'typing in appended editors pauses automatic adjacent-page loading',
    (tester) async {
      for (final legacy in [false, true]) {
        final calls = <int>[];
        final controller = _controller(create: (_, _) async {});
        final items = List.generate(20, (i) => 'Existing $i');
        await _table(
          tester,
          controller,
          items: items,
          onPageChange: (page) async => calls.add(page),
          onLoadMore: legacy ? () => calls.add(-1) : null,
        );
        final key = controller.creationDraftKeys.first;
        final input = find.byKey(ValueKey('inline-create-cell-$key-name'));
        await tester.scrollUntilVisible(
          find.byKey(ValueKey('inline-create-activate-$key-name')),
          200,
          scrollable: find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        await _activateCreation(tester, key, 'name');
        await tester.enterText(input, 'New after the last loaded page');
        await tester.pumpAndSettle();
        expect(calls, isEmpty);
        expect(
          tester.widget<TextField>(input).controller!.text,
          'New after the last loaded page',
        );
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
      }
    },
  );
  testWidgets('defaults and empty placeholders never create business records', (
    tester,
  ) async {
    final calls = <Map<String, dynamic>>[];
    final controller = _controller(
      create: (_, value) async => calls.add(value),
    );
    addTearDown(controller.dispose);
    expect(controller.appendRows, hasLength(3));
    expect(controller.dirty, isFalse);
    expect(await controller.save(_discardUpdate), isFalse);
    expect(calls, isEmpty);
    final key = controller.creationDraftKeys.first;
    controller.setCreationValue(key, 'name', 'Temporary');
    expect(controller.changedRows, 1);
    expect(controller.appendRows, hasLength(4));
    controller.setCreationValue(key, 'name', '');
    expect(controller.dirty, isFalse);
    expect(controller.changedRows, 0);
    expect(controller.appendRows, hasLength(3));
    for (var i = 0; i < 20; i++) {
      final empty = controller.creationDraftKeys.last;
      controller.setCreationValue(empty, 'name', 'Temporary $i');
      controller.setCreationValue(empty, 'name', '');
      expect(controller.appendRows, hasLength(3));
      expect(controller.creationDraftKeys, contains(empty));
    }
    expect(await controller.save(_discardUpdate), isFalse);
    expect(calls, isEmpty);
  });

  testWidgets('creation validates every required field before any command', (
    tester,
  ) async {
    var calls = 0;
    final controller = _controller(
      fields: const [
        _name,
        MasterFieldDef(key: 'styleId', label: 'Account style', required: true),
      ],
      create: (_, _) async => calls++,
    );
    addTearDown(controller.dispose);
    final key = controller.creationDraftKeys.first;
    controller.setCreationValue(key, 'name', 'Account A');
    expect(await controller.save(_discardUpdate), isFalse);
    expect(calls, 0);
    expect(controller.error, contains('Account style'));
    controller.setCreationValue(key, 'styleId', 'real-style-uuid');
    expect(await controller.save(_discardUpdate), isTrue);
    expect(calls, 1);
  });

  testWidgets(
    'successful creations disappear before a later failure and are not replayed',
    (tester) async {
      final calls = <String>[];
      var rejectSecond = true;
      final controller = _controller(
        create: (_, value) async {
          calls.add(value['name'] as String);
          if (value['name'] == 'Second' && rejectSecond) {
            throw ApiException('VALIDATION_FAILED', 'Fix the second row');
          }
        },
      );
      addTearDown(controller.dispose);
      final first = controller.creationDraftKeys.first;
      controller.setCreationValue(first, 'name', 'First');
      final second = controller.creationDraftKeys[1];
      controller.setCreationValue(second, 'name', 'Second');
      expect(await controller.save(_discardUpdate), isFalse);
      expect(calls, ['First', 'Second']);
      expect(controller.creationDraftKeys, isNot(contains(first)));
      expect(controller.changedRows, 1);
      rejectSecond = false;
      expect(await controller.save(_discardUpdate), isTrue);
      expect(calls, ['First', 'Second', 'Second']);
      expect(controller.changedRows, 0);
    },
  );

  testWidgets(
    'unknown create acknowledgement freezes that draft without blocking other new rows',
    (tester) async {
      final calls = <String>[];
      final controller = _controller(
        create: (_, value) async {
          calls.add(value['name'] as String);
          if (value['name'] == 'Unconfirmed') throw NetworkTimeoutException();
        },
      );
      addTearDown(controller.dispose);
      final key = controller.creationDraftKeys.first;
      controller.setCreationValue(key, 'name', 'Unconfirmed');
      expect(await controller.save(_discardUpdate), isFalse);
      expect(controller.creationIsUncertain(key), isTrue);
      expect(await controller.save(_discardUpdate), isFalse);
      expect(calls, ['Unconfirmed']);
      final next = controller.creationDraftKeys[1];
      controller.setCreationValue(next, 'name', 'Confirmed');
      expect(
        await controller.save(_discardUpdate),
        isFalse,
        reason: 'the unresolved draft remains visible',
      );
      expect(calls, ['Unconfirmed', 'Confirmed']);
      expect(controller.creationDraftKeys, isNot(contains(next)));
      expect(controller.changedRows, 1);
    },
  );

  testWidgets(
    'identity change stops the next command after an in-flight creation',
    (tester) async {
      final started = Completer<void>(), finish = Completer<void>();
      var calls = 0;
      final controller = _controller(
        create: (_, _) async {
          calls++;
          if (!started.isCompleted) started.complete();
          await finish.future;
        },
      );
      addTearDown(controller.dispose);
      controller.setCreationValue(
        controller.creationDraftKeys.first,
        'name',
        'First',
      );
      controller.setCreationValue(
        controller.creationDraftKeys[1],
        'name',
        'Second',
      );
      final saving = controller.save(_discardUpdate);
      await started.future;
      controller.cancel();
      finish.complete();
      expect(await saving, isFalse);
      expect(calls, 1);
      expect(controller.dirty, isFalse);
      expect(controller.appendRows, isEmpty);
    },
  );

  testWidgets(
    'precision and fixed context are preserved without submitting draft identity',
    (tester) async {
      Map<String, dynamic>? submitted;
      final controller = _controller(
        defaults: const {'categoryId': 'real-category', 'status': '使用'},
        create: (_, value) async => submitted = value,
      );
      addTearDown(controller.dispose);
      final key = controller.creationDraftKeys.first;
      controller.setCreationValue(key, 'name', 'New item');
      controller.setCreationValue(key, 'amount', '123456789.1234');
      expect(await controller.save(_discardUpdate), isTrue);
      expect(submitted!['amount'], '123456789.1234');
      expect(submitted!['categoryId'], 'real-category');
      expect(submitted!.containsKey('id'), isFalse);
      expect(submitted!.containsKey('version'), isFalse);
      expect(submitted!.values, isNot(contains(key)));
    },
  );

  testWidgets(
    'empty-table tail editors survive filters and keep focus as another blank row appears',
    (tester) async {
      final controller = _controller(create: (_, _) async {});
      addTearDown(controller.dispose);
      await _table(
        tester,
        controller,
        selectable: true,
        filters: const {'name': 'absent'},
      );
      expect(find.text('暂无数据'), findsNothing);
      final key = controller.creationDraftKeys.last;
      final input = find.byKey(ValueKey('inline-create-cell-$key-name'));
      await _activateCreation(tester, key, 'name');
      await tester.enterText(input, 'Continuous entry');
      await tester.pumpAndSettle();
      expect(controller.appendRows, hasLength(4));
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Continuous entry',
      );
      expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue);
      await tester.enterText(input, '');
      await tester.pumpAndSettle();
      expect(controller.appendRows, hasLength(3));
      expect(
        find.byKey(ValueKey('inline-create-cell-$key-name')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<EditableText>(
              find.descendant(of: input, matching: find.byType(EditableText)),
            )
            .focusNode
            .hasFocus,
        isTrue,
      );
      expect(
        find.byType(Checkbox),
        findsOneWidget,
        reason: 'only the real table header owns selection',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unmapped required fields are reachable and the local dialog closes on cancellation',
    (tester) async {
      final controller = _controller(
        fields: const [
          _name,
          MasterFieldDef(
            key: 'styleId',
            label: 'Account style',
            required: true,
          ),
        ],
        create: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await _table(tester, controller);
      final key = controller.creationDraftKeys.first;
      await tester.tap(find.byKey(ValueKey('inline-create-other-$key')));
      await tester.pumpAndSettle();
      expect(find.text('Account style'), findsWidgets);
      controller.cancel();
      await tester.pumpAndSettle();
      expect(find.text('Account style'), findsNothing);
      expect(controller.dirty, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the details entry only appears while a required field is unreachable',
    (tester) async {
      // 必填字段已有默认值（如货品「状态」）：即使不在可见列也不再出现入口。
      final controller = _controller(
        fields: const [
          _name,
          MasterFieldDef(
            key: 'styleId',
            label: 'Account style',
            required: true,
          ),
        ],
        defaults: const {'status': '使用', 'styleId': 'preset'},
        create: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await _table(tester, controller);
      final key = controller.creationDraftKeys.first;
      expect(find.byKey(ValueKey('inline-create-other-$key')), findsNothing);

      // 行已编辑但缺的只是选填字段：入口同样保持沉默。
      await _activateCreation(tester, key, 'name');
      await tester.enterText(
        find.byKey(ValueKey('inline-create-cell-$key-name')),
        'Typed',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('inline-create-other-$key')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'required empty creation cells carry the shared red frame until filled',
    (tester) async {
      final controller = _controller(create: (_, _) async {});
      addTearDown(controller.dispose);
      await _table(tester, controller);
      final key = controller.creationDraftKeys.first;
      final preview = tester.widget<UtenInlineEditCell>(
        find.ancestor(
          of: find.byKey(ValueKey('inline-create-activate-$key-name')),
          matching: find.byType(UtenInlineEditCell),
        ),
      );
      expect(preview.requiredEmpty, isTrue);
      await _activateCreation(tester, key, 'name');
      await _activateCreation(tester, key, 'amount');
      final error = Theme.of(
        tester.element(find.byKey(ValueKey('inline-create-cell-$key-name'))),
      ).colorScheme.error;
      InputDecoration decorationOf(String fieldKey) => tester
          .widget<TextField>(
            find.byKey(ValueKey('inline-create-cell-$key-$fieldKey')),
          )
          .decoration!;
      // 必填空：红框（全站「空时红框」约定，宽 1.5）；选填：普通边框。
      expect(decorationOf('name').enabledBorder?.borderSide.color, error);
      expect(decorationOf('name').enabledBorder?.borderSide.width, 1.5);
      expect(decorationOf('amount').enabledBorder, isNull);
      await tester.enterText(
        find.byKey(ValueKey('inline-create-cell-$key-name')),
        'Filled',
      );
      await tester.pumpAndSettle();
      expect(decorationOf('name').enabledBorder, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'required selects announce requiredness before the row is edited',
    (tester) async {
      final controller = _controller(
        fields: [
          _name,
          const MasterFieldDef(
            key: 'kind',
            label: 'Kind',
            type: MasterFieldType.select,
            required: true,
            options: [MasterSelectOption(value: 'a', label: 'A')],
          ),
        ],
        create: (_, _) async {},
      );
      addTearDown(controller.dispose);
      await _table(
        tester,
        controller,
        extraColumns: [
          MasterColumnDef(
            key: 'kind',
            label: 'Kind',
            width: 160,
            value: (_) => '',
          ),
        ],
      );
      final selects = tester
          .widgetList<UtenDropdownField>(find.byType(UtenDropdownField))
          .where((field) => field.items.any((item) => item.value == 'a'))
          .toList();
      expect(
        selects,
        isEmpty,
        reason: 'Blank rows do not mount dropdown editors eagerly',
      );
      final key = controller.creationDraftKeys.first;
      await _activateCreation(tester, key, 'kind');
      final activatedSelects = tester
          .widgetList<UtenDropdownField>(find.byType(UtenDropdownField))
          .where((field) => field.items.any((item) => item.value == 'a'))
          .toList();
      // 空白草稿行不止一行，每行的必填下拉都要带 required 红框语义。
      expect(activatedSelects, hasLength(1));
      expect(activatedSelects.single.required, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}
