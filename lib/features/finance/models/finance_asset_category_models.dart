import 'finance_asset_models.dart';

class FinanceAssetCategory {
  const FinanceAssetCategory({
    required this.id,
    required this.objectType,
    required this.code,
    required this.name,
    required this.status,
    required this.costStyleId,
    required this.expenseStyleId,
    required this.clearingStyleId,
    required this.defaultMethod,
    required this.defaultUsefulMonths,
    required this.requiredDocumentCodes,
    required this.rowVersion,
    this.accumulatedStyleId,
    this.defaultResidualRate,
    this.effectiveFrom,
    this.categoryVersion,
  });

  final String id;
  final FinanceAssetLedger objectType;
  final String code;
  final String name;
  final String status;
  final String costStyleId;
  final String? accumulatedStyleId;
  final String expenseStyleId;
  final String clearingStyleId;
  final String defaultMethod;
  final int defaultUsefulMonths;
  final String? defaultResidualRate;
  final String? effectiveFrom;
  final List<String> requiredDocumentCodes;
  final int rowVersion;
  final int? categoryVersion;

  factory FinanceAssetCategory.fromJson(Map<String, dynamic> json) {
    String text(List<String> keys, [String fallback = '']) {
      for (final key in keys) {
        final value = json[key];
        if (value != null) return value.toString();
      }
      return fallback;
    }

    String? optional(List<String> keys) {
      final value = text(keys).trim();
      return value.isEmpty ? null : value;
    }

    final rawDocuments = json['requiredDocumentCodes'];
    return FinanceAssetCategory(
      id: text(const ['id']),
      objectType: text(const ['objectType']).toUpperCase() == 'DEFERRED_EXPENSE'
          ? FinanceAssetLedger.deferredExpense
          : FinanceAssetLedger.fixedAsset,
      code: text(const ['code']),
      name: text(const ['name']),
      status: text(const ['status'], 'DRAFT'),
      costStyleId: text(const [
        'costStyleId',
        'costAccountId',
        'assetAccountId',
      ]),
      accumulatedStyleId: optional(const [
        'accumulatedStyleId',
        'accumulatedDepreciationAccountId',
        'accumulatedAccountId',
      ]),
      expenseStyleId: text(const [
        'expenseStyleId',
        'expenseAccountId',
        'depreciationExpenseAccountId',
        'amortizationExpenseAccountId',
      ]),
      clearingStyleId: text(const [
        'clearingStyleId',
        'clearingAccountId',
        'disposalClearingAccountId',
      ]),
      defaultMethod: text(const [
        'defaultMethod',
        'method',
        'depreciationMethod',
        'amortizationMethod',
      ]),
      defaultUsefulMonths: switch (json['defaultUsefulMonths'] ??
          json['usefulMonths']) {
        final num value => value.toInt(),
        final Object value => int.tryParse(value.toString()) ?? 0,
        _ => 0,
      },
      defaultResidualRate: optional(const [
        'defaultResidualRate',
        'salvageRate',
      ]),
      effectiveFrom: optional(const ['effectiveFrom', 'effectiveDate']),
      requiredDocumentCodes: rawDocuments is List
          ? rawDocuments
                .map((item) => item.toString().trim())
                .where((item) => item.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      rowVersion: switch (json['rowVersion']) {
        final num value => value.toInt(),
        final Object value => int.tryParse(value.toString()) ?? 0,
        _ => 0,
      },
      categoryVersion: switch (json['categoryVersion']) {
        final num value => value.toInt(),
        final Object value => int.tryParse(value.toString()),
        _ => null,
      },
    );
  }
}

class FinanceAssetCategoryInput {
  const FinanceAssetCategoryInput({
    required this.objectType,
    required this.code,
    required this.name,
    required this.costStyleId,
    required this.expenseStyleId,
    required this.clearingStyleId,
    required this.defaultMethod,
    required this.defaultUsefulMonths,
    required this.requiredDocumentCodes,
    this.accumulatedStyleId,
    this.defaultResidualRate,
    this.effectiveFrom,
    this.expectedVersion,
  });

  final FinanceAssetLedger objectType;
  final String code;
  final String name;
  final String costStyleId;
  final String? accumulatedStyleId;
  final String expenseStyleId;
  final String clearingStyleId;
  final String defaultMethod;
  final int defaultUsefulMonths;
  final String? defaultResidualRate;
  final String? effectiveFrom;
  final List<String> requiredDocumentCodes;
  final int? expectedVersion;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'objectType': objectType.apiValue,
    'code': code.trim(),
    'name': name.trim(),
    'costStyleId': costStyleId.trim(),
    if (objectType == FinanceAssetLedger.fixedAsset)
      'accumulatedStyleId': accumulatedStyleId?.trim(),
    'expenseStyleId': expenseStyleId.trim(),
    'clearingStyleId': clearingStyleId.trim(),
    'defaultMethod': defaultMethod.trim(),
    'defaultUsefulMonths': defaultUsefulMonths,
    if (objectType == FinanceAssetLedger.fixedAsset &&
        defaultResidualRate?.trim().isNotEmpty == true)
      'defaultResidualRate': defaultResidualRate!.trim(),
    if (effectiveFrom?.trim().isNotEmpty == true)
      'effectiveFrom': effectiveFrom!.trim(),
    'requiredDocumentCodes': requiredDocumentCodes,
    if (expectedVersion != null) 'expectedVersion': expectedVersion,
  };
}
