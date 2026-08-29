import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/production_fqc_pending_count_provider.dart';
import '../../warehouse/providers/production_finished_inbound_task_count_provider.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';

class ProductionFqcInspectionsPage extends ConsumerStatefulWidget {
  const ProductionFqcInspectionsPage({super.key});

  @override
  ConsumerState<ProductionFqcInspectionsPage> createState() =>
      _ProductionFqcInspectionsPageState();
}

class _ProductionFqcInspectionsPageState
    extends ConsumerState<ProductionFqcInspectionsPage> {
  PagedResult<ProductionFqcInspection>? _result;
  bool _loading = false;
  String? _error;
  String _status = 'ACTIVE';
  String _keyword = '';
  int _requestVersion = 0;
  bool _canDecideByScope = false;
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _load({int? page}) async {
    final requestVersion = ++_requestVersion;
    final requestedPage = page ?? _result?.page ?? 1;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repository = ref.read(productionFqcRepositoryProvider);
      final permissions = ref.read(currentPermissionsProvider);
      final mayApprove =
          ref.read(isSuperAdminProvider) ||
          permissions.contains(Perm.productionQualityInspectionApprove);
      var canDecideByScope = false;
      if (mayApprove) {
        try {
          canDecideByScope = await repository.canDecide();
        } catch (_) {
          // Fail closed for the write button; task reading remains available.
        }
      }
      final result = await repository.list(
        status: _status,
        keyword: _keyword,
        page: requestedPage,
      );
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _result = result;
        _canDecideByScope = canDecideByScope;
        _loading = false;
      });
      ref.invalidate(productionFqcPendingCountProvider);
    } on ApiException catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '生产成品质检任务加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _switchStatus(String status) async {
    if (_status == status) return;
    setState(() => _status = status);
    await _load(page: 1);
  }

  void _searchChanged(String value) {
    setState(() => _keyword = value);
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) _load(page: 1);
    });
  }

  Future<void> _openDecision(ProductionFqcInspection inspection) async {
    final result = await showDialog<ProductionFqcDecisionResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ProductionFqcDecisionDialog(inspection: inspection),
    );
    if (result == null || !mounted) return;
    _applyDecisionResult(result.inspection);
    context.appSuccess(result.replay ? '该质检决定已安全重放' : '质检决定已保存');
    await _load(page: _result?.page ?? 1);
  }

  void _applyDecisionResult(ProductionFqcInspection updated) {
    final current = _result;
    if (current == null) return;
    final items = [...current.items];
    final index = items.indexWhere((item) => item.id == updated.id);
    if (index < 0) return;
    final remainsVisible = _matchesCurrentFilter(updated);
    if (remainsVisible) {
      items[index] = updated;
    } else {
      items.removeAt(index);
    }
    final total = (current.total + (remainsVisible ? 0 : -1)).clamp(0, 1 << 31);
    setState(() {
      _result = PagedResult(
        items: items,
        page: current.page,
        size: current.size,
        total: total,
        totalPages: total == 0 ? 0 : (total + current.size - 1) ~/ current.size,
      );
    });
  }

  bool _matchesCurrentFilter(ProductionFqcInspection item) {
    final statusMatch = switch (_status) {
      'ACTIVE' => item.active,
      'ALL' => true,
      _ => item.status == _status,
    };
    if (!statusMatch) return false;
    final keyword = _keyword.trim().toLowerCase();
    if (keyword.isEmpty) return true;
    final text = [
      item.reportNo,
      item.planNo,
      item.goodsCode,
      item.goodsName,
      item.colorName,
    ].whereType<String>().join(' ').toLowerCase();
    return text.contains(keyword);
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume(RouteName.productionFqcInspections, _load);
    final permissions = ref.watch(currentPermissionsProvider);
    final canApprove =
        (ref.watch(isSuperAdminProvider) ||
            permissions.contains(Perm.productionQualityInspectionApprove)) &&
        _canDecideByScope;
    final result = _result;
    return Scaffold(
      appBar: UtenAppBar(
        title: '生产成品质检',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && result != null,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && result == null
            ? const UtenSkeletonList()
            : _error != null && result == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildList(canApprove),
      ),
    );
  }

  Widget _buildList(bool canApprove) {
    final result =
        _result ??
        const PagedResult<ProductionFqcInspection>(
          items: [],
          page: 1,
          size: 40,
          total: 0,
          totalPages: 0,
        );
    final visible = result.items;
    return UtenContentContainer.narrow(
      child: RefreshIndicator(
        onRefresh: () => _load(page: result.page),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          children: [
            UtenSearchBar(
              hint: '搜索报工单 / 生产计划 / 货品',
              initialValue: _keyword,
              onChanged: _searchChanged,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                ChoiceChip(
                  label: const Text('待处理'),
                  selected: _status == 'ACTIVE',
                  onSelected: (_) => _switchStatus('ACTIVE'),
                ),
                ChoiceChip(
                  label: const Text('已决定'),
                  selected: _status == 'RESOLVED',
                  onSelected: (_) => _switchStatus('RESOLVED'),
                ),
                ChoiceChip(
                  label: const Text('已取消'),
                  selected: _status == 'CANCELLED',
                  onSelected: (_) => _switchStatus('CANCELLED'),
                ),
                ChoiceChip(
                  label: const Text('全部'),
                  selected: _status == 'ALL',
                  onSelected: (_) => _switchStatus('ALL'),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            _FqcSummary(total: result.total, status: _status),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Semantics(
                liveRegion: true,
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s16),
            if (visible.isEmpty)
              SizedBox(
                height: 360,
                child: UtenEmpty(
                  icon: Icons.fact_check_outlined,
                  message: _keyword.trim().isEmpty
                      ? '当前筛选下没有生产质检任务'
                      : '没有匹配的生产质检任务',
                  description: '报工审核后自动进入待检；只有 PASS 数量会形成仓库待点收入库任务。',
                ),
              )
            else
              for (var index = 0; index < visible.length; index++) ...[
                _FqcInspectionCard(
                  key: ValueKey('production-fqc-${visible[index].id}'),
                  inspection: visible[index],
                  canApprove: canApprove,
                  onDecide: () => _openDecision(visible[index]),
                ),
                if (index != visible.length - 1)
                  const SizedBox(height: UtenSpacing.s12),
              ],
            if (result.totalPages > 1) ...[
              const SizedBox(height: UtenSpacing.s20),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: UtenSpacing.s16,
                runSpacing: UtenSpacing.s8,
                children: [
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_left_rounded,
                    onPressed: !_loading && result.page > 1
                        ? () => _load(page: result.page - 1)
                        : null,
                    child: const Text('上一页'),
                  ),
                  Text('第 ${result.page} / ${result.totalPages} 页'),
                  UtenButton(
                    size: UtenButtonSize.large,
                    type: UtenButtonType.tonal,
                    icon: Icons.chevron_right_rounded,
                    onPressed: !_loading && result.page < result.totalPages
                        ? () => _load(page: result.page + 1)
                        : null,
                    child: const Text('下一页'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: UtenSpacing.s24),
          ],
        ),
      ),
    );
  }
}

class _FqcSummary extends StatelessWidget {
  const _FqcSummary({required this.total, required this.status});

  final int total;
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusLabel = switch (status) {
      'ACTIVE' => '待处理',
      'RESOLVED' => '已决定',
      'CANCELLED' => '已取消',
      _ => '全部任务',
    };
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.42),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(
          color: theme.colorScheme.secondary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: theme.colorScheme.secondary.withValues(alpha: 0.12),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Icon(
              Icons.fact_check_outlined,
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$statusLabel $total 条',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                const Text('报工量、合格量和仓库实收量分层记录；不合格数量不会进入库存、iqty 或上层齐套。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FqcInspectionCard extends StatelessWidget {
  const _FqcInspectionCard({
    super.key,
    required this.inspection,
    required this.canApprove,
    required this.onDecide,
  });

  final ProductionFqcInspection inspection;
  final bool canApprove;
  final VoidCallback onDecide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final statusType = switch (inspection.status) {
      'PENDING' => UtenStatusBadgeType.info,
      'PARTIAL' => UtenStatusBadgeType.warning,
      'RESOLVED' => UtenStatusBadgeType.success,
      'CANCELLED' => UtenStatusBadgeType.neutral,
      _ => UtenStatusBadgeType.neutral,
    };
    final statusLabel = switch (inspection.status) {
      'PENDING' => '待检',
      'PARTIAL' => '部分决定',
      'RESOLVED' => '已决定',
      'CANCELLED' => '来源报工已红冲',
      _ => inspection.status,
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(label: statusLabel, type: statusType),
                Text(
                  [
                    inspection.goodsCode,
                    inspection.goodsName,
                  ].whereType<String>().join(' '),
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            _line('报工单', inspection.reportNo ?? '—'),
            _line('生产计划', inspection.planNo ?? '—'),
            _line('颜色', inspection.colorName ?? '—'),
            _line(
              '数量',
              '报工 ${_qty(inspection.reportedQty)} · '
                  '合格 ${_qty(inspection.passedQty)} · '
                  '不合格 ${_qty(inspection.failedQty)} · '
                  '待检 ${_qty(inspection.remainingQty)}',
            ),
            _line('已生成入库', _qty(inspection.authorizedInboundQty)),
            if (inspection.active && canApprove) ...[
              const SizedBox(height: UtenSpacing.s8),
              SizedBox(
                width: double.infinity,
                child: UtenButton(
                  size: UtenButtonSize.large,
                  icon: Icons.rule_rounded,
                  onPressed: onDecide,
                  child: const Text('登记检验决定'),
                ),
              ),
            ] else if (inspection.active) ...[
              const SizedBox(height: UtenSpacing.s8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.lock_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  Expanded(
                    child: Text(
                      '当前为只读查看；质检决定由具备审批权限且属于品质任务组织的人员登记。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 88, child: Text('$label：')),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _ProductionFqcDecisionDialog extends ConsumerStatefulWidget {
  const _ProductionFqcDecisionDialog({required this.inspection});

  final ProductionFqcInspection inspection;

  @override
  ConsumerState<_ProductionFqcDecisionDialog> createState() =>
      _ProductionFqcDecisionDialogState();
}

class _ProductionFqcDecisionDialogState
    extends ConsumerState<_ProductionFqcDecisionDialog> {
  String _decision = 'PASS';
  String _disposition = 'REWORK';
  late final TextEditingController _passQty;
  late final TextEditingController _failQty;
  final TextEditingController _reason = TextEditingController();
  final String _idempotencyKey = 'fqc-decision-${const Uuid().v4()}';
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _passQty = TextEditingController(
      text: _qty(widget.inspection.remainingQty),
    );
    _failQty = TextEditingController(
      text: _qty(widget.inspection.remainingQty),
    );
  }

  @override
  void dispose() {
    _passQty.dispose();
    _failQty.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final remaining = widget.inspection.remainingQty;
    final pass = double.tryParse(_passQty.text.trim());
    final fail = double.tryParse(_failQty.text.trim());
    String? validation;
    if (_decision == 'PASS') {
      if (pass == null || pass <= 0 || pass > remaining + 0.000001) {
        validation = '合格数量必须大于 0 且不超过待检数量';
      }
    } else if (_decision == 'FAIL') {
      if (fail == null || fail <= 0 || fail > remaining + 0.000001) {
        validation = '不合格数量必须大于 0 且不超过待检数量';
      }
    } else {
      if (pass == null ||
          pass <= 0 ||
          fail == null ||
          fail <= 0 ||
          pass + fail > remaining + 0.000001) {
        validation = '部分决定必须同时填写正的合格/不合格数量，且合计不超过待检数量';
      }
    }
    if (_decision != 'PASS' && _reason.text.trim().length < 2) {
      validation ??= '不合格或部分决定必须填写至少 2 个字的原因';
    }
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(productionFqcRepositoryProvider)
          .decide(
            id: widget.inspection.id,
            decision: _decision,
            idempotencyKey: _idempotencyKey,
            passQty: _decision == 'FAIL' ? null : pass,
            failQty: _decision == 'PASS' ? null : fail,
            dispositionCode: _decision == 'PASS' ? null : _disposition,
            reason: _decision == 'PASS' ? null : _reason.text,
          );
      ref.invalidate(productionFqcPendingCountProvider);
      ref.invalidate(warehouseProductionFinishedInboundPendingCountProvider);
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = '质检决定保存失败，请保持本窗口并重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('登记生产成品质检决定'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '待检 ${_qty(widget.inspection.remainingQty)} '
                '${widget.inspection.unitName ?? ''}',
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final entry in const [
                    ('PASS', '合格'),
                    ('PARTIAL', '部分合格'),
                    ('FAIL', '不合格'),
                  ])
                    ChoiceChip(
                      label: Text(entry.$2),
                      selected: _decision == entry.$1,
                      onSelected: _saving
                          ? null
                          : (_) => setState(() => _decision = entry.$1),
                    ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              if (_decision != 'FAIL')
                TextField(
                  controller: _passQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: '本次合格数量',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '合格数量会生成仓库待点收任务，尚不直接增加库存。',
                  ),
                ),
              if (_decision != 'PASS') ...[
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _failQty,
                  enabled: !_saving,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: '本次不合格数量'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                DropdownButtonFormField<String>(
                  initialValue: _disposition,
                  decoration: const InputDecoration(labelText: '不合格处置'),
                  items: const [
                    DropdownMenuItem(value: 'REWORK', child: Text('返工')),
                    DropdownMenuItem(value: 'SCRAP', child: Text('报废')),
                    DropdownMenuItem(value: 'REJECT', child: Text('拒收/退回')),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) =>
                            setState(() => _disposition = value ?? 'REWORK'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  controller: _reason,
                  enabled: !_saving,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '不合格原因',
                    // uten-field-message-exception: raw-message - AlertDialog intrinsic sizing rejects LayoutBuilder helper widgets.
                    helperText: '至少 2 个字，保留为不可变质量决定证据。',
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check_rounded),
          label: Text(_saving ? '保存中…' : '确认决定'),
        ),
      ],
    );
  }
}

String _qty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');
