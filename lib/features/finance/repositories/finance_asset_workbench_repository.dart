import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/finance_asset_models.dart';

abstract interface class FinanceAssetWorkbenchRepository {
  Future<FinanceAssetOverview> loadOverview();

  Future<PagedResult<FinanceAssetSummary>> list(
    FinanceAssetLedger ledger, {
    FinanceAssetQuery query = const FinanceAssetQuery(),
  });

  Future<FinanceAssetDetail> detail(FinanceAssetLedger ledger, String id);

  Future<FinanceAssetWorkflowResponse> createDraft(
    FinanceAssetLedger ledger,
    FinanceAssetDraftInput input,
  );

  Future<FinanceAssetWorkflowResponse> updateDraft(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetDraftInput input,
  );

  Future<void> deleteDraft(
    FinanceAssetLedger ledger,
    String id, {
    required int expectedVersion,
  });

  Future<FinanceAssetWorkflowResponse> assetAction(
    FinanceAssetLedger ledger,
    String id,
    String action,
    FinanceAssetWorkflowRequest request,
  );

  Future<AssetPostingPreview> previewPosting({
    required AssetPostingRunType runType,
    required String period,
    String? bookType,
  });

  Future<FinanceAssetWorkflowResponse> postingAction(
    String id,
    String action, {
    String? token,
    int? expectedVersion,
    String? reason,
  });

  Future<PagedResult<AssetPostingRun>> listPostingRuns({
    int page = 1,
    int size = 20,
    String? period,
    AssetPostingRunType? runType,
    String? status,
  });

  Future<List<AssetPeriod>> listPeriods();

  Future<FinanceAssetWorkflowResponse> periodAction(
    String period,
    String action, {
    required String reason,
    int? expectedVersion,
  });
}

class ApiFinanceAssetWorkbenchRepository
    implements FinanceAssetWorkbenchRepository {
  ApiFinanceAssetWorkbenchRepository(this._api);

  final ApiClient _api;

  static const _postingRunsPath = '/finance/asset-posting-runs';
  static const _periodsPath = '/finance/asset-periods';

  @override
  Future<FinanceAssetOverview> loadOverview() async {
    return FinanceAssetOverview.fromJson(
      await _api.get('/finance/asset-workbench/overview'),
    );
  }

  @override
  Future<PagedResult<FinanceAssetSummary>> list(
    FinanceAssetLedger ledger, {
    FinanceAssetQuery query = const FinanceAssetQuery(),
  }) async {
    final response = await _api.get(ledger.basePath, query: query.toQuery());
    return financePagedResult(
      response,
      (json) => FinanceAssetSummary.fromJson(json, ledger),
    );
  }

  @override
  Future<FinanceAssetDetail> detail(
    FinanceAssetLedger ledger,
    String id,
  ) async {
    return FinanceAssetDetail.fromJson(
      await _api.get('${ledger.basePath}/$id'),
      ledger,
    );
  }

  @override
  Future<FinanceAssetWorkflowResponse> createDraft(
    FinanceAssetLedger ledger,
    FinanceAssetDraftInput input,
  ) async {
    return FinanceAssetWorkflowResponse.fromJson(
      await _api.post(ledger.basePath, body: input.toJson()),
    );
  }

  @override
  Future<FinanceAssetWorkflowResponse> updateDraft(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetDraftInput input,
  ) async {
    return FinanceAssetWorkflowResponse.fromJson(
      await _api.put('${ledger.basePath}/$id', body: input.toJson()),
    );
  }

  @override
  Future<void> deleteDraft(
    FinanceAssetLedger ledger,
    String id, {
    required int expectedVersion,
  }) {
    final path = Uri(
      path: '${ledger.basePath}/$id',
      queryParameters: <String, String>{
        'expectedVersion': expectedVersion.toString(),
      },
    ).toString();
    return _api.delete(path);
  }

  @override
  Future<FinanceAssetWorkflowResponse> assetAction(
    FinanceAssetLedger ledger,
    String id,
    String action,
    FinanceAssetWorkflowRequest request,
  ) async {
    return FinanceAssetWorkflowResponse.fromJson(
      await _api.post('${ledger.basePath}/$id/$action', body: request.toJson()),
    );
  }

  @override
  Future<AssetPostingPreview> previewPosting({
    required AssetPostingRunType runType,
    required String period,
    String? bookType,
  }) async {
    return AssetPostingPreview.fromJson(
      await _api.post(
        '$_postingRunsPath/preview',
        body: <String, dynamic>{
          'runType': runType.apiValue,
          'period': period.trim(),
          if (bookType?.trim().isNotEmpty == true) 'bookType': bookType!.trim(),
        },
      ),
    );
  }

  @override
  Future<FinanceAssetWorkflowResponse> postingAction(
    String id,
    String action, {
    String? token,
    int? expectedVersion,
    String? reason,
  }) async {
    return FinanceAssetWorkflowResponse.fromJson(
      await _api.post(
        '$_postingRunsPath/$id/$action',
        body: <String, dynamic>{
          if (token?.isNotEmpty == true) 'token': token,
          'expectedVersion': ?expectedVersion,
          if (reason?.trim().isNotEmpty == true) 'reason': reason!.trim(),
        },
      ),
    );
  }

  @override
  Future<PagedResult<AssetPostingRun>> listPostingRuns({
    int page = 1,
    int size = 20,
    String? period,
    AssetPostingRunType? runType,
    String? status,
  }) async {
    final response = await _api.get(
      _postingRunsPath,
      query: <String, dynamic>{
        'page': page,
        'size': size,
        if (period?.trim().isNotEmpty == true) 'period': period!.trim(),
        if (runType != null) 'runType': runType.apiValue,
        if (status?.trim().isNotEmpty == true) 'status': status!.trim(),
      },
    );
    return financePagedResult(
      response,
      AssetPostingRun.fromJson,
      fallbackItemsKey: 'runs',
    );
  }

  @override
  Future<List<AssetPeriod>> listPeriods() async {
    final response = financeAssetPayload(await _api.get(_periodsPath));
    final raw = response['items'] ?? response['periods'];
    if (raw is! List<dynamic>) return const <AssetPeriod>[];
    return raw
        .whereType<Map<Object?, Object?>>()
        .map((item) => AssetPeriod.fromJson(Map<String, dynamic>.from(item)))
        .toList(growable: false);
  }

  @override
  Future<FinanceAssetWorkflowResponse> periodAction(
    String period,
    String action, {
    required String reason,
    int? expectedVersion,
  }) async {
    return FinanceAssetWorkflowResponse.fromJson(
      await _api.post(
        '$_periodsPath/$period/$action',
        body: <String, dynamic>{
          'reason': reason.trim(),
          'expectedVersion': ?expectedVersion,
        },
      ),
    );
  }
}

extension FinanceAssetWorkflowRepositoryX on FinanceAssetWorkbenchRepository {
  Future<FinanceAssetWorkflowResponse> submit(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'submit', request);

  Future<FinanceAssetWorkflowResponse> approve(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'approve', request);

  Future<FinanceAssetWorkflowResponse> reject(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'reject', request);

  Future<FinanceAssetWorkflowResponse> activate(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'activate', request);

  Future<FinanceAssetWorkflowResponse> transfer(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'transfer', request);

  Future<FinanceAssetWorkflowResponse> changeOperatingStatus(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'operating-status', request);

  Future<FinanceAssetWorkflowResponse> dispose(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'dispose', request);

  Future<FinanceAssetWorkflowResponse> terminate(
    FinanceAssetLedger ledger,
    String id,
    FinanceAssetWorkflowRequest request,
  ) => assetAction(ledger, id, 'terminate', request);

  Future<FinanceAssetWorkflowResponse> submitPostingRun(
    String id, {
    required String token,
    int? expectedVersion,
  }) => postingAction(
    id,
    'submit',
    token: token,
    expectedVersion: expectedVersion,
  );

  Future<FinanceAssetWorkflowResponse> approvePostingRun(
    String id, {
    String? token,
    int? expectedVersion,
  }) => postingAction(
    id,
    'approve',
    token: token,
    expectedVersion: expectedVersion,
  );

  Future<FinanceAssetWorkflowResponse> postPostingRun(
    String id, {
    required String token,
    int? expectedVersion,
  }) =>
      postingAction(id, 'post', token: token, expectedVersion: expectedVersion);

  Future<FinanceAssetWorkflowResponse> reversePostingRun(
    String id, {
    required String reason,
    String? token,
    int? expectedVersion,
  }) => postingAction(
    id,
    'reverse',
    token: token,
    expectedVersion: expectedVersion,
    reason: reason,
  );

  Future<FinanceAssetWorkflowResponse> closePeriod(
    String period, {
    required String reason,
    int? expectedVersion,
  }) => periodAction(
    period,
    'close',
    reason: reason,
    expectedVersion: expectedVersion,
  );

  Future<FinanceAssetWorkflowResponse> reopenPeriod(
    String period, {
    required String reason,
    int? expectedVersion,
  }) => periodAction(
    period,
    'reopen',
    reason: reason,
    expectedVersion: expectedVersion,
  );
}

final financeAssetWorkbenchRepositoryProvider =
    Provider<FinanceAssetWorkbenchRepository>((ref) {
      return ApiFinanceAssetWorkbenchRepository(ref.watch(apiClientProvider));
    });
