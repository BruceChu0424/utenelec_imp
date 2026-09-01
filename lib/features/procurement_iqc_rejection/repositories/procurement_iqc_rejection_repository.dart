import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/procurement_iqc_rejection.dart';

abstract interface class ProcurementIqcRejectionGateway {
  Future<PagedResult<ProcurementIqcRejectionCase>> list(
    ProcurementIqcRejectionFilter filter,
  );

  Future<ProcurementIqcRejectionCounts> counts(
    ProcurementIqcRejectionFilter filter,
  );

  Future<ProcurementIqcRejectionDetail> detail(String id);

  Future<ProcurementIqcRejectionDetail> recordReturn(
    String id,
    ProcurementIqcRecordReturnCommand command,
  );

  Future<ProcurementIqcRejectionDetail> confirmCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  );

  Future<ProcurementIqcRejectionDetail> closeNoCredit(
    String id,
    ProcurementIqcReasonCommand command,
  );

  Future<ProcurementIqcRejectionDetail> reverse(
    String id,
    ProcurementIqcReasonCommand command,
  );

  Future<ProcurementIqcRejectionDetail> retryFinanceProjection(
    String id,
    ProcurementIqcReasonCommand command,
  );
}

class ProcurementIqcRejectionRepository
    implements ProcurementIqcRejectionGateway {
  const ProcurementIqcRejectionRepository(this.api);

  static const _base = '/procurement/iqc-rejections';
  final ApiClient api;

  @override
  Future<PagedResult<ProcurementIqcRejectionCase>> list(
    ProcurementIqcRejectionFilter filter,
  ) async {
    final json = await api.get(_base, query: filter.toQuery());
    return PagedResult.fromJson(json, ProcurementIqcRejectionCase.fromJson);
  }

  @override
  Future<ProcurementIqcRejectionCounts> counts(
    ProcurementIqcRejectionFilter filter,
  ) async {
    final json = await api.get(
      '$_base/counts',
      query: {
        if (filter.receiptType != null)
          'receiptType': filter.receiptType!.apiValue,
        if (filter.keyword.trim().isNotEmpty) 'keyword': filter.keyword.trim(),
      },
    );
    return ProcurementIqcRejectionCounts.fromJson(json);
  }

  @override
  Future<ProcurementIqcRejectionDetail> detail(String id) async {
    final json = await api.get('$_base/$id');
    return ProcurementIqcRejectionDetail.fromJson(json);
  }

  @override
  Future<ProcurementIqcRejectionDetail> recordReturn(
    String id,
    ProcurementIqcRecordReturnCommand command,
  ) => _command(id, 'record-return', command.toJson());

  @override
  Future<ProcurementIqcRejectionDetail> confirmCredit(
    String id,
    ProcurementIqcConfirmCreditCommand command,
  ) => _command(id, 'confirm-credit', command.toJson());

  @override
  Future<ProcurementIqcRejectionDetail> closeNoCredit(
    String id,
    ProcurementIqcReasonCommand command,
  ) => _command(id, 'close-no-credit', command.toJson());

  @override
  Future<ProcurementIqcRejectionDetail> reverse(
    String id,
    ProcurementIqcReasonCommand command,
  ) => _command(id, 'reverse', command.toJson());

  @override
  Future<ProcurementIqcRejectionDetail> retryFinanceProjection(
    String id,
    ProcurementIqcReasonCommand command,
  ) => _command(id, 'retry-finance-projection', command.toJson());

  Future<ProcurementIqcRejectionDetail> _command(
    String id,
    String action,
    Map<String, dynamic> body,
  ) async {
    final json = await api.post('$_base/$id/$action', body: body);
    return ProcurementIqcRejectionDetail.fromJson(json);
  }
}

final procurementIqcRejectionRepositoryProvider =
    Provider<ProcurementIqcRejectionRepository>(
      (ref) => ProcurementIqcRejectionRepository(ref.watch(apiClientProvider)),
    );

final procurementIqcRejectionOpenCountProvider = FutureProvider<int>((
  ref,
) async {
  final counts = await ref
      .watch(procurementIqcRejectionRepositoryProvider)
      .counts(const ProcurementIqcRejectionFilter());
  return counts.open;
});
