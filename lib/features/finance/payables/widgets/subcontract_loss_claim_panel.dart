import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/inputs/uten_search_bar.dart';
import '../../../../components/layout/uten_adaptive_panel.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/network/latest_request_guard.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../models/subcontract_loss_claim.dart';
import '../repositories/subcontract_loss_claim_repository.dart';
import 'subcontract_loss_claim_detail_panel.dart';

class SubcontractLossClaimPanel extends ConsumerStatefulWidget {
  const SubcontractLossClaimPanel({super.key});

  @override
  ConsumerState<SubcontractLossClaimPanel> createState() =>
      _SubcontractLossClaimPanelState();
}

class _SubcontractLossClaimPanelState
    extends ConsumerState<SubcontractLossClaimPanel> {
  final _requests = LatestRequestGuard();
  SubcontractLossClaimPageResult? _result;
  bool _loading = false;
  String? _error;
  String _keyword = '';
  String? _status;
  int _page = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load([int? requestedPage]) async {
    final generation = _requests.begin();
    final page = requestedPage ?? _page;
    setState(() {
      _page = page;
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .list(status: _status, keyword: _keyword, page: page);
      if (!mounted || !_requests.isCurrent(generation)) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } on ApiException catch (error) {
      _fail(generation, error.message);
    } catch (_) {
      _fail(generation, '服务暂不可用，请稍后重试');
    }
  }

  void _fail(int generation, String message) {
    if (!mounted || !_requests.isCurrent(generation)) return;
    setState(() {
      _loading = false;
      _error = message;
    });
    context.appError('加载委外超耗责任失败：$message');
  }

  void _changeFilter(VoidCallback change) {
    setState(change);
    _load(1);
  }

  Future<void> _open(SubcontractLossClaimSummary item) async {
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 900,
      compactHeightFactor: 0.94,
      panelElevation: 12,
      builder: (_) => SubcontractLossClaimDetailPanel(
        caseId: item.id,
        onChanged: () => _load(),
      ),
    );
    if (mounted) await _load();
  }

  List<MasterColumnDef<SubcontractLossClaimSummary>> _columns({
    required bool canViewFinancialAmounts,
  }) => [
    MasterColumnDef(
      key: 'wasteBillNo',
      label: '损耗单号',
      width: 160,
      value: (item) => item.wasteBillNo,
    ),
    MasterColumnDef(
      key: 'supplierName',
      label: '委外商',
      width: 210,
      value: (item) => [
        item.supplierCode,
        item.supplierName,
      ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
    ),
    MasterColumnDef(
      key: 'actualLossQty',
      label: '实际损耗',
      width: 110,
      type: 'number',
      value: (item) => item.actualLossQty,
    ),
    MasterColumnDef(
      key: 'allowedLossQty',
      label: '允许损耗',
      width: 110,
      type: 'number',
      value: (item) => item.allowedLossQty,
    ),
    MasterColumnDef(
      key: 'excessLossQty',
      label: '超耗',
      width: 110,
      type: 'number',
      value: (item) => item.excessLossQty,
    ),
    if (canViewFinancialAmounts) ...[
      MasterColumnDef(
        key: 'lossBookValueLocal',
        label: '账面损失(本币)',
        width: 150,
        type: 'money',
        value: (item) => item.lossBookValueLocal,
      ),
      MasterColumnDef(
        key: 'claimAmountLocal',
        label: '索赔额(本币)',
        width: 140,
        type: 'money',
        value: (item) => item.claimAmountLocal,
      ),
    ],
    MasterColumnDef(
      key: 'status',
      label: '责任状态',
      width: 130,
      value: (item) => item.statusLabel,
    ),
    MasterColumnDef(
      key: 'createdAt',
      label: '生成时间',
      width: 170,
      value: (item) => item.createdAt,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _result?.total ?? 0;
    final canViewFinancialAmounts = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.financeViewAll);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Row(
            children: [
              Icon(
                Icons.gavel_outlined,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '委外超耗责任 ($total)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              UtenButton(
                type: UtenButtonType.ghost,
                icon: Icons.refresh_rounded,
                onPressed: _loading ? null : () => _load(),
                child: const Text('刷新'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenSearchBar(
                key: const ValueKey('subcontract-loss-claim-search'),
                hint: '搜索损耗单号、委外商编号或名称',
                initialValue: _keyword,
                onChanged: (value) => _changeFilter(() => _keyword = value),
              ),
              const SizedBox(height: UtenSpacing.s8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _statusChip('全部', null),
                    _statusChip('待处理', 'OPEN'),
                    _statusChip('争议中', 'DISPUTED'),
                    _statusChip('待履约', 'AWAITING_FULFILLMENT'),
                    _statusChip('已解决', 'RESOLVED'),
                    _statusChip('已反转', 'REVERSED'),
                  ],
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: MasterDataTableView<SubcontractLossClaimSummary>(
            primary: true,
            columns: _columns(canViewFinancialAmounts: canViewFinancialAmounts),
            items: _result?.items ?? const [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            onRowTap: _open,
            isLoading: _loading && _result == null,
            loadingMore: _loading && _result != null,
            error: _error,
            onRetry: () => _load(),
            emptyMessage: '暂无符合条件的委外超耗责任单',
            currentPage: _result?.page ?? 1,
            totalPages: _result?.totalPages ?? 1,
            onPageChange: (page) => _load(page),
          ),
        ),
      ],
    );
  }

  Widget _statusChip(String label, String? value) => Padding(
    padding: const EdgeInsets.only(right: UtenSpacing.s4),
    child: ChoiceChip(
      label: Text(label),
      selected: _status == value,
      onSelected: (_) => _changeFilter(() => _status = value),
    ),
  );
}
