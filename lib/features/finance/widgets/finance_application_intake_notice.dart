import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_client.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../config/finance_requirement_names.dart';

/// A native cash draft must not imply it can bypass enabled payment approval.
class FinanceApplicationIntakeNotice extends ConsumerStatefulWidget {
  const FinanceApplicationIntakeNotice({super.key});
  @override
  ConsumerState<FinanceApplicationIntakeNotice> createState() => _NoticeState();
}

class _NoticeState extends ConsumerState<FinanceApplicationIntakeNotice> {
  late final ApiClient _api;
  late final int _epoch;
  Map<String, dynamic>? _data;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await _api.get('/finance/applications/intake');
      if (_current) setState(() => _data = data);
    } catch (_) {
      /* The original server write guard remains authoritative. */
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_current || _data?['enabled'] != true) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('新支出须先完成各部门申请流程。批准支付后，在原申请登记实际付款；本页草稿不会自动付款。'),
          if (_data?['canApply'] == true)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => context.push(
                '/finance/applications/new?kind=PAYMENT_APPLICATION',
              ),
              child: const Text(FinanceRequirementNames.financeApplications),
            )
          else
            const Text('请由有申请填写权限的经办人建立付款或预付申请。'),
        ],
      ),
    );
  }
}
