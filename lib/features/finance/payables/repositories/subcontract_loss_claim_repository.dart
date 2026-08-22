import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/network/api_client.dart';
import '../models/subcontract_loss_claim.dart';

class SubcontractLossClaimRepository {
  SubcontractLossClaimRepository(this.api);

  final ApiClient api;
  static const String _base = '/finance/subcontract-loss-claims';

  Future<SubcontractLossClaimPageResult> list({
    String? supplierId,
    String? status,
    String? keyword,
    int page = 1,
    int size = 30,
  }) async {
    final json = await api.get(
      _base,
      query: {
        if (supplierId?.isNotEmpty == true) 'supplierId': supplierId,
        if (status?.isNotEmpty == true) 'status': status,
        if (keyword?.trim().isNotEmpty == true) 'keyword': keyword!.trim(),
        'page': page,
        'size': size,
      },
    );
    return SubcontractLossClaimPageResult.fromJson(json);
  }

  Future<SubcontractLossClaimDetail> detail(String id) async {
    final json = await api.get('$_base/$id');
    return SubcontractLossClaimDetail.fromJson(json);
  }

  Future<SubcontractLossClaimDetail> decide(
    String id, {
    required int expectedVersion,
    required bool disputed,
    required String reason,
    List<SubcontractLossResolutionInput> resolutions = const [],
  }) async {
    final json = await api.post(
      '$_base/$id/decision',
      body: {
        'expectedVersion': expectedVersion,
        'disputed': disputed,
        'reason': reason.trim(),
        'resolutions': [
          for (final resolution in resolutions) resolution.toJson(),
        ],
      },
    );
    return SubcontractLossClaimDetail.fromJson(json);
  }

  Future<SubcontractLossClaimDetail> fulfill(
    String caseId,
    String resolutionId, {
    required int expectedCaseVersion,
    required String fulfilledQuantity,
    String? fulfilledAmountLocal,
    required String evidenceReference,
    String? fulfillmentDocType,
    String? fulfillmentDocId,
    String? fulfillmentDocItemId,
    String? fulfillmentDocNo,
    String? accountId,
    String? cashReceiptDate,
    String? note,
  }) async {
    final json = await api.post(
      '$_base/$caseId/resolutions/$resolutionId/fulfill',
      body: {
        'expectedCaseVersion': expectedCaseVersion,
        'fulfilledQuantity': fulfilledQuantity,
        'fulfilledAmountLocal': ?fulfilledAmountLocal,
        'evidenceReference': evidenceReference.trim(),
        'fulfillmentDocType': ?fulfillmentDocType,
        'fulfillmentDocId': ?fulfillmentDocId,
        'fulfillmentDocItemId': ?fulfillmentDocItemId,
        if (fulfillmentDocNo?.trim().isNotEmpty == true)
          'fulfillmentDocNo': fulfillmentDocNo!.trim(),
        'accountId': ?accountId,
        'cashReceiptDate': ?cashReceiptDate,
        if (note?.trim().isNotEmpty == true) 'note': note!.trim(),
      },
    );
    return SubcontractLossClaimDetail.fromJson(json);
  }

  Future<SubcontractLossClaimDetail> reverseFulfillment(
    String caseId,
    String resolutionId, {
    required int expectedCaseVersion,
    required String reason,
  }) async {
    final json = await api.post(
      '$_base/$caseId/resolutions/$resolutionId/reverse-fulfillment',
      body: {
        'expectedCaseVersion': expectedCaseVersion,
        'reason': reason.trim(),
      },
    );
    return SubcontractLossClaimDetail.fromJson(json);
  }

  Future<SubcontractLossClaimDetail> reverse(
    String id, {
    required int expectedVersion,
    required String reason,
  }) async {
    final json = await api.post(
      '$_base/$id/reverse',
      body: {'expectedVersion': expectedVersion, 'reason': reason.trim()},
    );
    return SubcontractLossClaimDetail.fromJson(json);
  }
}

final subcontractLossClaimRepositoryProvider =
    Provider<SubcontractLossClaimRepository>(
      (ref) => SubcontractLossClaimRepository(ref.watch(apiClientProvider)),
    );
