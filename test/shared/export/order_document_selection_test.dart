import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/export/order_document_selection.dart';

void main() {
  ({List<ExportOrderDocument> documents, String? issue}) select(
    List<ExportOrderDocument?> rows, {
    int? selected,
  }) => orderDocumentSelection(
    rows: rows,
    selectedRowCount: selected ?? rows.length,
    documentOf: (row) => row,
    emptyMessage: '请选择',
    unsupportedMessage: '无法查看单据',
  );

  test('deduplicates documents after validating every selected row', () {
    final result = select([
      (id: 'one', number: 'PO-1'),
      (id: 'one', number: 'PO-1'),
      (id: 'two', number: 'PO-2'),
    ]);
    expect(result.issue, isNull);
    expect(result.documents.map((document) => document.id), ['one', 'two']);
    expect(select([(id: 'one', number: 'PO-1'), null]).issue, '无法查看单据');
    expect(select([(id: '', number: 'PO-1')]).issue, '无法查看单据');
  });

  test('stale and empty selections cannot silently export a subset', () {
    expect(select([]).issue, '请选择');
    expect(
      select([(id: 'one', number: 'PO-1')], selected: 2).issue,
      '所选任务已发生变化，请刷新后重新选择',
    );
  });

  test('resource limit applies to whole documents, not repeated task rows', () {
    expect(
      select(List.generate(101, (i) => (id: '$i', number: '$i'))).issue,
      contains('100'),
    );
    expect(
      select(List.generate(101, (_) => (id: 'one', number: 'PO-1'))).issue,
      isNull,
    );
  });
}
