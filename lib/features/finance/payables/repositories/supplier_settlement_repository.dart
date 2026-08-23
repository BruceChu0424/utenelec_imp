import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/supplier_settlement.dart';

class SupplierSettlementRepository {
  SupplierSettlementRepository(this.api);

  final ApiClient api;
  static const _base = '/finance/supplier-settlements';

  Future<SupplierSettlementPageResult> list({
    String? supplierId,
    String? periodStart,
    String? status,
    String? keyword,
    int page = 1,
    int size = 30,
  }) async {
    final json = await api.get(
      _base,
      query: {
        if (supplierId?.isNotEmpty == true) 'supplierId': supplierId,
        if (periodStart?.isNotEmpty == true) 'periodStart': periodStart,
        if (status?.isNotEmpty == true) 'status': status,
        if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
        'page': page,
        'size': size,
      },
    );
    return SupplierSettlementPageResult.fromJson(json);
  }

  Future<SupplierSettlementDetail> detail(String id) async {
    final json = await api.get('$_base/$id');
    return SupplierSettlementDetail.fromJson(json);
  }

  Future<SupplierSettlementDetail> freeze({
    required String supplierId,
    required String currencyId,
    required String periodStart,
    required String settlementMethodId,
  }) async {
    final json = await api.post(
      _base,
      body: {
        'supplierId': supplierId,
        'currencyId': currencyId,
        'periodStart': periodStart,
        'settlementMethodId': settlementMethodId,
      },
    );
    return SupplierSettlementDetail.fromJson(json);
  }

  Future<SupplierSettlementDetail> supplierConfirm(
    String id, {
    required int expectedVersion,
    required String reference,
    String? note,
  }) => _confirm(
    '$id/supplier-confirm',
    expectedVersion: expectedVersion,
    reference: reference,
    note: note,
  );

  Future<SupplierSettlementDetail> internalConfirm(
    String id, {
    required int expectedVersion,
    String? note,
  }) => _confirm(
    '$id/internal-confirm',
    expectedVersion: expectedVersion,
    note: note,
  );

  Future<SupplierSettlementDetail> _confirm(
    String path, {
    required int expectedVersion,
    String? reference,
    String? note,
  }) async {
    final json = await api.post(
      '$_base/$path',
      body: {
        'expectedVersion': expectedVersion,
        if (reference?.trim().isNotEmpty == true)
          'reference': reference!.trim(),
        if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
      },
    );
    return SupplierSettlementDetail.fromJson(json);
  }

  Future<SupplierSettlementDetail> dispute(
    String id, {
    required int expectedVersion,
    required String reason,
  }) => _reasonAction(
    '$id/dispute',
    expectedVersion: expectedVersion,
    reason: reason,
  );

  Future<SupplierSettlementDetail> reverse(
    String id, {
    required int expectedVersion,
    required String reason,
  }) => _reasonAction(
    '$id/reverse',
    expectedVersion: expectedVersion,
    reason: reason,
  );

  Future<SupplierSettlementDetail> _reasonAction(
    String path, {
    required int expectedVersion,
    required String reason,
  }) async {
    final json = await api.post(
      '$_base/$path',
      body: {'expectedVersion': expectedVersion, 'reason': reason.trim()},
    );
    return SupplierSettlementDetail.fromJson(json);
  }
}

final supplierSettlementRepositoryProvider =
    Provider<SupplierSettlementRepository>(
      (ref) => SupplierSettlementRepository(ref.watch(apiClientProvider)),
    );
