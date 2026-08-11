import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/finance_asset_models.dart';

class FinanceAssetWorkbenchOverview {
  const FinanceAssetWorkbenchOverview({
    required this.metrics,
    required this.policyReady,
    required this.missingPolicyItems,
    required this.postedWorkflowsEnabled,
    required this.operationalBlockers,
  });

  final FinanceAssetOverview metrics;
  final bool policyReady;
  final List<String> missingPolicyItems;
  final bool postedWorkflowsEnabled;
  final List<String> operationalBlockers;

  factory FinanceAssetWorkbenchOverview.fromJson(Map<String, dynamic> source) {
    final json = financeAssetPayload(source);
    final missing = json['missingPolicyItems'];
    final items = missing is List
        ? missing
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final ready = switch (json['policyReady']) {
      final bool value => value,
      final Object value => value.toString().toLowerCase() == 'true',
      _ => items.isEmpty,
    };
    final blockerSource = json['operationalBlockers'];
    final blockers = blockerSource is List
        ? blockerSource
              .map((item) => item.toString().trim())
              .where((item) => item.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    final postedWorkflowsEnabled = switch (json['postedWorkflowsEnabled']) {
      final bool value => value,
      final Object value => value.toString().toLowerCase() == 'true',
      _ => false,
    };
    return FinanceAssetWorkbenchOverview(
      metrics: FinanceAssetOverview.fromJson(json),
      policyReady: ready,
      missingPolicyItems: items,
      postedWorkflowsEnabled: postedWorkflowsEnabled,
      operationalBlockers: blockers,
    );
  }
}

abstract interface class FinanceAssetOverviewRepository {
  Future<FinanceAssetWorkbenchOverview> load();
}

class ApiFinanceAssetOverviewRepository
    implements FinanceAssetOverviewRepository {
  ApiFinanceAssetOverviewRepository(this._api);
  final ApiClient _api;

  @override
  Future<FinanceAssetWorkbenchOverview> load() async {
    return FinanceAssetWorkbenchOverview.fromJson(
      await _api.get('/finance/asset-workbench/overview'),
    );
  }
}

final financeAssetOverviewRepositoryProvider =
    Provider<FinanceAssetOverviewRepository>((ref) {
      return ApiFinanceAssetOverviewRepository(ref.watch(apiClientProvider));
    });
