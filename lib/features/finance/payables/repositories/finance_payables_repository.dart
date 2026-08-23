import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/finance_payable.dart';

class FinancePayablesFilter {
  const FinancePayablesFilter({
    this.businessType,
    this.supplierId,
    this.status,
    this.settlementMethodId,
    this.keyword,
    this.dateFrom,
    this.dateTo,
    this.dueFrom,
    this.dueTo,
  });

  final String? businessType;
  final String? supplierId;
  final String? status;
  final String? settlementMethodId;
  final String? keyword;
  final String? dateFrom;
  final String? dateTo;
  final String? dueFrom;
  final String? dueTo;
}

class FinancePayableOffsetTarget {
  const FinancePayableOffsetTarget({
    required this.payableId,
    required this.amountOriginal,
  });

  final String payableId;
  final String amountOriginal;

  Map<String, dynamic> toJson() => {
    'payableId': payableId,
    'amountOriginal': amountOriginal,
  };
}

class FinancePayablesRepository {
  FinancePayablesRepository(this.api);

  final ApiClient api;

  Future<FinancePayablesResult> list({
    int page = 1,
    int size = 30,
    FinancePayablesFilter filter = const FinancePayablesFilter(),
    String? sort,
    String? order,
  }) async {
    final json = await api.get(
      '/finance/payables',
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (filter.businessType?.isNotEmpty == true)
          'businessType': filter.businessType,
        if (filter.supplierId?.isNotEmpty == true)
          'supplierId': filter.supplierId,
        if (filter.status?.isNotEmpty == true) 'status': filter.status,
        if (filter.settlementMethodId?.isNotEmpty == true)
          'settlementMethodId': filter.settlementMethodId,
        if (filter.keyword?.trim().isNotEmpty == true)
          'keyword': filter.keyword!.trim(),
        if (filter.dateFrom?.isNotEmpty == true) 'dateFrom': filter.dateFrom,
        if (filter.dateTo?.isNotEmpty == true) 'dateTo': filter.dateTo,
        if (filter.dueFrom?.isNotEmpty == true) 'dueFrom': filter.dueFrom,
        if (filter.dueTo?.isNotEmpty == true) 'dueTo': filter.dueTo,
        if (sort?.isNotEmpty == true) 'sort': sort,
        if (order?.isNotEmpty == true) 'order': order,
      },
    );
    return FinancePayablesResult.fromJson(json);
  }

  Future<String?> applyOffset({
    required String sourceLedgerId,
    required String effectiveDate,
    required String reason,
    required List<FinancePayableOffsetTarget> targets,
  }) async {
    final json = await api.post(
      '/finance/payable-offsets',
      body: {
        'sourceLedgerId': sourceLedgerId,
        'effectiveDate': effectiveDate,
        'reason': reason.trim(),
        'targets': [for (final target in targets) target.toJson()],
      },
    );
    return json['offsetBatchId']?.toString();
  }
}

final financePayablesRepositoryProvider = Provider<FinancePayablesRepository>(
  (ref) => FinancePayablesRepository(ref.watch(apiClientProvider)),
);
