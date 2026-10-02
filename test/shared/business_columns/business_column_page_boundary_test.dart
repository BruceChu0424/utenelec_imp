import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/sales/widgets/sales_grid_columns.dart';
import 'package:uten_imp/shared/business_columns/business_column.dart';
import 'package:uten_imp/shared/business_columns/business_column_picker.dart';
import 'package:uten_imp/shared/business_columns/business_columns_repository.dart';
import 'package:uten_imp/shared/business_columns/business_columns_row.dart';

const _reference = BusinessColumn(id: 'reference', name: '客户货号', value: 'A01');
const _newColumn = BusinessColumn(id: 'new', name: '补充信息');

class _Repository extends BusinessColumnsRepository {
  _Repository() : super(ApiClient(Dio()));
  int creates = 0;
  Completer<BusinessColumn>? pendingCreate;

  @override
  Future<List<BusinessColumn>> search(String scope, String query) async => [
    _newColumn,
  ];

  @override
  Future<bool> supportsArithmetic(String scope) async => true;

  @override
  Future<BusinessColumn> create({
    required String scope,
    required String name,
    required String type,
    required String operation,
  }) async {
    creates++;
    if (pendingCreate != null) return pendingCreate!.future;
    return _newColumn;
  }
}

Future<void> _open(
  WidgetTester tester, {
  required _Repository repository,
  required SalesGridRow row,
  required bool Function() isEditingEnabled,
  required VoidCallback onChanged,
}) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        businessColumnsRepositoryProvider.overrideWithValue(repository),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => addBusinessGridColumn<EditableGridRow>(
                context,
                scope: 'sales_order',
                hiddenColumns: const [],
                rows: [row],
                isEditingEnabled: isEditingEnabled,
                onChanged: onChanged,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

Future<void> _prepareCreate(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('business-column-view-create')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('business-column-name')), '新说明');
  await tester.pump(const Duration(milliseconds: 300));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a stale create button cannot write after page editing closes', (
    tester,
  ) async {
    final repository = _Repository();
    final row = SalesGridRow();
    addTearDown(row.dispose);
    var editing = true;
    var changes = 0;
    await _open(
      tester,
      repository: repository,
      row: row,
      isEditingEnabled: () => editing,
      onChanged: () => changes++,
    );
    await _prepareCreate(tester);
    editing = false;
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pumpAndSettle();
    expect(repository.creates, 0);
    expect(changes, 0);
    expect(row.extraColumnDefinitions, isEmpty);
  });

  testWidgets('a pending catalog creation cannot mutate a now read-only form', (
    tester,
  ) async {
    final repository = _Repository()
      ..pendingCreate = Completer<BusinessColumn>();
    final row = SalesGridRow();
    addTearDown(row.dispose);
    var editing = true;
    var changes = 0;
    await _open(
      tester,
      repository: repository,
      row: row,
      isEditingEnabled: () => editing,
      onChanged: () => changes++,
    );
    await _prepareCreate(tester);
    await tester.tap(find.byKey(const Key('business-column-create')));
    await tester.pump();
    expect(repository.creates, 1);
    editing = false;
    repository.pendingCreate!.complete(_newColumn);
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(row.extraColumnDefinitions, isEmpty);
    expect(find.text('当前页面不可编辑列，请返回单据录入页修改。'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale reuse and removal callbacks recheck the page boundary', (
    tester,
  ) async {
    final row = SalesGridRow()..addExtraColumn(_reference);
    addTearDown(row.dispose);
    var editing = true;
    var changes = 0;
    await _open(
      tester,
      repository: _Repository(),
      row: row,
      isEditingEnabled: () => editing,
      onChanged: () => changes++,
    );
    editing = false;
    await tester.tap(find.text('补充信息'));
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(row.extraColumnDefinitions.single.id, 'reference');

    editing = true;
    await tester.tap(find.byKey(const Key('business-column-view-manage')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('business-column-remove-reference')));
    await tester.pumpAndSettle();
    editing = false;
    await tester.tap(find.byKey(const Key('business-column-confirm-remove')));
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(row.extraColumnSnapshots.single.value, 'A01');
  });

  for (final remove in [false, true]) {
    testWidgets(
      'late ${remove ? 'remove' : 'add'} choices cannot mutate rows',
      (tester) async {
        final row = SalesGridRow()..addExtraColumn(_reference);
        addTearDown(row.dispose);
        var editing = true;
        var changes = 0;
        await _open(
          tester,
          repository: _Repository(),
          row: row,
          isEditingEnabled: () => editing,
          onChanged: () => changes++,
        );
        final context = tester.element(
          find.byKey(const Key('business-column-name')),
        );
        editing = false;
        Navigator.of(context).pop(
          remove
              ? const BusinessColumnChoice(removeColumnId: 'reference')
              : const BusinessColumnChoice(column: _newColumn),
        );
        await tester.pumpAndSettle();
        expect(changes, 0);
        expect(row.extraColumnSnapshots.single.id, 'reference');
        expect(row.extraColumnSnapshots.single.value, 'A01');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
