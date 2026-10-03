import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';

import '../models/finance_doc.dart';

const financeIntakeKind = 'FINANCE_DOCUMENT_INTAKE';
const financeIntakeContentTypes = <String, String>{
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xls': 'application/vnd.ms-excel',
  'csv': 'text/csv',
  'pdf': 'application/pdf',
};

enum FinanceIntakeField {
  bankReference('银行流水号'),
  transactionDate('交易日期'),
  accountAmount('账户实际收支金额'),
  currencyCode('回单币种'),
  bankFee('银行手续费');

  const FinanceIntakeField(this.label);
  final String label;
}

/// The original money text is authoritative; never round or pass through double.
class FinanceIntakeResult {
  FinanceIntakeResult.fromJson(Map<String, dynamic> json)
    : docType = json['docType'],
      fileName = (json['source'] as Map?)?['fileName'],
      sourceSha256 = (json['source'] as Map?)?['sha256'],
      fields = {
        for (final field in FinanceIntakeField.values)
          if (_checkedValue(field, (json['fields'] as Map?)?[field.name])
              case final String value)
            field: value,
      },
      fieldSources = {
        for (final field in FinanceIntakeField.values)
          if ((json['fieldSources'] as Map?)?[field.name]
              case final String value)
            field: value.length <= 500 ? value : value.substring(0, 500),
      },
      warnings = (json['warnings'] as List? ?? const [])
          .whereType<String>()
          .take(12)
          .map((v) => v.length <= 500 ? v : v.substring(0, 500))
          .toList();

  final Object? docType, fileName, sourceSha256;
  final Map<FinanceIntakeField, String> fields, fieldSources;
  final List<String> warnings;

  bool matchesSource(PlatformFile file, FinanceDocType type) =>
      (type == FinanceDocType.receipt || type == FinanceDocType.payment) &&
      docType == type.name &&
      fileName == file.name &&
      sourceSha256 is String &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sourceSha256 as String) &&
      file.bytes?.isNotEmpty == true &&
      sha256.convert(file.bytes!).toString() == sourceSha256;

  static String? _checkedValue(FinanceIntakeField field, Object? raw) {
    if (raw is! String) return null;
    switch (field) {
      case FinanceIntakeField.accountAmount:
      case FinanceIntakeField.bankFee:
        if (!RegExp(r'^\d{1,12}\.\d{2}$').hasMatch(raw)) return null;
        if (field == FinanceIntakeField.accountAmount &&
            BigInt.parse(raw.replaceAll('.', '')) <= BigInt.zero) {
          return null;
        }
        return raw;
      case FinanceIntakeField.transactionDate:
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) return null;
        final date = DateTime.tryParse(raw);
        return date != null && date.toIso8601String().substring(0, 10) == raw
            ? raw
            : null;
      case FinanceIntakeField.currencyCode:
        return {'CNY', 'USD', 'EUR', 'HKD', 'JPY', 'GBP', 'KRW'}.contains(raw)
            ? raw
            : null;
      case FinanceIntakeField.bankReference:
        return RegExp(r'^[A-Za-z0-9][A-Za-z0-9_/-]{2,79}$').hasMatch(raw)
            ? raw
            : null;
    }
  }
}

/// Only fields explicitly selected in the review are exposed for form application.
/// This patch carries no ledger, account, client/supplier or exchange-rate IDs.
class FinanceIntakePatch {
  const FinanceIntakePatch({
    required this.jobId,
    required this.file,
    required this.sourceSha256,
    required this.docType,
    required this.confirmedFields,
    required this.sourceCurrencyCode,
  });

  final String jobId, sourceSha256;
  final PlatformFile file;
  final FinanceDocType docType;

  /// Source metadata remains present even when currency is not selected.
  final String? sourceCurrencyCode;
  final Map<FinanceIntakeField, String> confirmedFields;
  String? get bankReference =>
      confirmedFields[FinanceIntakeField.bankReference];
  String? get transactionDate =>
      confirmedFields[FinanceIntakeField.transactionDate];

  /// A bank date is not the document's business date or an exact booking instant.
  String get transactionDatePrecision => 'DATE';
  String? get accountAmount =>
      confirmedFields[FinanceIntakeField.accountAmount];
  String? get currencyCode => confirmedFields[FinanceIntakeField.currencyCode];
  String? get bankFee => confirmedFields[FinanceIntakeField.bankFee];
}
