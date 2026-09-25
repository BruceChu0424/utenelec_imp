import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import 'master_data_table_view.dart';

final goodsBomLearningProvider = FutureProvider.autoDispose
    .family<Map<String, dynamic>, String>(
      (ref, id) async => Map<String, dynamic>.from(
        await ref.read(apiClientProvider).get('/master/goods/$id/bom-learning')
            as Map,
      ),
    );

Future<void> showGoodsBomLearning(BuildContext context, String goodsId) =>
    showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 900,
      builder: (_) => GoodsBomLearningPanel(goodsId: goodsId),
    );

class GoodsBomLearningPanel extends ConsumerWidget {
  const GoodsBomLearningPanel({super.key, required this.goodsId});
  final String goodsId;
  static String _quantity(dynamic value) => value is num
      ? value.toStringAsFixed(6).replaceFirst(RegExp(r'\.?0+$'), '')
      : '—';
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final result = ref.watch(goodsBomLearningProvider(goodsId));
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.bomLearningTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            Text(l10n.bomLearningHelp),
            const SizedBox(height: 16),
            Expanded(
              child: result.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Column(
                  children: [
                    Text(
                      error is ApiException
                          ? error.message
                          : l10n.materialDiscoveryLoadFailed,
                    ),
                    UtenButton(
                      onPressed: () =>
                          ref.invalidate(goodsBomLearningProvider(goodsId)),
                      child: Text(l10n.materialDiscoveryRetry),
                    ),
                  ],
                ),
                data: (data) {
                  if (data['active'] != true) {
                    return Text(l10n.bomLearningInactive);
                  }
                  final materials = [
                    for (final row in data['materials'] as List? ?? [])
                      Map<String, dynamic>.from(row as Map),
                  ];
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        data['enabled'] == true && data['blockedReason'] == null
                            ? l10n.bomLearningAuto
                            : l10n.bomLearningPaused,
                      ),
                      Text(
                        '${l10n.bomLearningOutput}: ${_quantity(data['totalOutputQty'])} ${data['unitName'] ?? ''} · ${l10n.bomLearningSamples}: ${data['sampleCount'] ?? 0}',
                      ),
                      const SizedBox(height: 12),
                      Expanded(
                        child: MasterDataTableView<Map<String, dynamic>>(
                          items: materials,
                          facets: const {},
                          nullCounts: const {},
                          filters: const {},
                          onFilterChanged: (_, _) {},
                          columns: [
                            MasterColumnDef(
                              key: 'goodsName',
                              label: l10n.materialDiscoveryPick,
                              width: 180,
                              value: (row) => row['goodsName'] as String?,
                            ),
                            MasterColumnDef(
                              key: 'goodsCode',
                              label: l10n.materialDiscoveryCode,
                              width: 100,
                              value: (row) => row['goodsCode'] as String?,
                            ),
                            MasterColumnDef(
                              key: 'colorName',
                              label: l10n.materialDiscoveryColor,
                              width: 90,
                              value: (row) => row['colorName'] as String?,
                            ),
                            MasterColumnDef(
                              key: 'unitName',
                              label: l10n.materialDiscoveryUnit,
                              width: 70,
                              value: (row) => row['unitName'] as String?,
                            ),
                            MasterColumnDef(
                              key: 'totalNetQty',
                              label: l10n.bomLearningNet,
                              width: 130,
                              type: 'number',
                              value: (row) => _quantity(row['totalNetQty']),
                            ),
                            MasterColumnDef(
                              key: 'averageQty',
                              label: l10n.bomLearningAverage,
                              width: 130,
                              type: 'number',
                              value: (row) => _quantity(row['averageQty']),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
