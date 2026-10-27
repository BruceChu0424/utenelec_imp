import 'document_batch_limits.dart';

typedef ExportOrderDocument = ({String id, String number});

/// Validate every selected row before deduplicating whole documents. A row
/// selected for another action must not silently disappear from an export.
({List<ExportOrderDocument> documents, String? issue})
orderDocumentSelection<T>({
  required List<T> rows,
  required int selectedRowCount,
  required ExportOrderDocument? Function(T row) documentOf,
  required String emptyMessage,
  required String unsupportedMessage,
}) {
  final documents = <String, ExportOrderDocument>{};
  var unsupported = false;
  for (final row in rows) {
    final document = documentOf(row);
    if (document == null || document.id.trim().isEmpty) {
      unsupported = true;
    } else {
      documents.putIfAbsent(document.id, () => document);
    }
  }
  final String? issue;
  if (rows.length != selectedRowCount) {
    issue = '所选任务已发生变化，请刷新后重新选择';
  } else if (rows.isEmpty) {
    issue = emptyMessage;
  } else if (unsupported) {
    issue = unsupportedMessage;
  } else if (documents.length > maxWorkbenchDocumentExport) {
    issue = '一次最多导出 $maxWorkbenchDocumentExport 份单据，请分批选择';
  } else {
    issue = null;
  }
  return (documents: documents.values.toList(growable: false), issue: issue);
}
