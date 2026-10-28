import '../../../shared/report/account_statement_column_query.dart';
import 'report_column.dart';
import 'report_cell.dart';

export '../../../shared/report/account_statement_column_query.dart';

/// The statement grid and paper preview use the same choice labels and exact
/// amount formatter; raw enum codes must not reappear only in the printout.
String? formatAccountStatementReportCell(
  ReportColumn column,
  Map<String, dynamic> row,
) => switch (column.key) {
  'entryKind' => accountStatementChoiceLabel(
    accountStatementEntryKinds,
    row[column.key]?.toString(),
  ),
  'sourceDocType' => accountStatementChoiceLabel(
    accountStatementSources,
    row[column.key]?.toString(),
  ),
  _ => formatReportCell(column, row),
};
