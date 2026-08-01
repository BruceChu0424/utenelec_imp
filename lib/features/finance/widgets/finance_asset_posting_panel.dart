import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_workbench_repository.dart';
import 'finance_asset_ui.dart';

class FinanceAssetPostingPanel extends ConsumerStatefulWidget {
  const FinanceAssetPostingPanel({super.key, required this.capabilities});

  final FinanceAssetCapabilities capabilities;

  @override
  ConsumerState<FinanceAssetPostingPanel> createState() =>
      _FinanceAssetPostingPanelState();
}

class _FinanceAssetPostingPanelState
    extends ConsumerState<FinanceAssetPostingPanel> {
  final _periodController = TextEditingController(text: currentFinancePeriod());
  final _runsGuard = LatestRequestGuard();
  final _periodsGuard = LatestRequestGuard();
  AssetPostingRunType _runType = AssetPostingRunType.depreciation;
  AssetPostingPreview? _preview;
  int? _workflowVersion;
  Set<String> _workflowAllowedActions = const <String>{};
  String? _previewError;
  String _workflowStatus = '';
  List<AssetPostingRun> _runs = const [];
  List<AssetPeriod> _periods = const [];
  bool _runsLoading = true;
  bool _periodsLoading = true;
  String? _runsError;
  String? _periodsError;

  @override
  void initState() {
    super.initState();
    _loadRuns();
    _loadPeriods();
  }

  @override
  void dispose() {
    _periodController.dispose();
    super.dispose();
  }

  Future<void> _loadRuns() async {
    final generation = _runsGuard.begin();
    setState(() {
      _runsLoading = true;
      _runsError = null;
    });
    try {
      final result = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .listPostingRuns();
      if (!mounted || !_runsGuard.isCurrent(generation)) return;
      setState(() {
        _runs = result.items;
        _runsLoading = false;
      });
    } catch (_) {
      if (!mounted || !_runsGuard.isCurrent(generation)) return;
      setState(() {
        _runsLoading = false;
        _runsError = '过账批次加载失败';
      });
    }
  }

  Future<void> _loadPeriods() async {
    final generation = _periodsGuard.begin();
    setState(() {
      _periodsLoading = true;
      _periodsError = null;
    });
    try {
      final result = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .listPeriods();
      if (!mounted || !_periodsGuard.isCurrent(generation)) return;
      setState(() {
        _periods = result;
        _periodsLoading = false;
      });
    } catch (_) {
      if (!mounted || !_periodsGuard.isCurrent(generation)) return;
      setState(() {
        _periodsLoading = false;
        _periodsError = '资产期间加载失败';
      });
    }
  }

  Future<void> _previewPosting() async {
    final error = validateFinancePeriod(_periodController.text);
    if (error != null) {
      setState(() => _previewError = error);
      return;
    }
    setState(() {
      _previewError = null;
      _preview = null;
      _workflowStatus = '';
      _workflowVersion = null;
      _workflowAllowedActions = const <String>{};
    });
    try {
      final preview = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .previewPosting(
            runType: _runType,
            period: _periodController.text.trim(),
          );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _workflowStatus = preview.status.toUpperCase();
        _workflowVersion = preview.version;
        _workflowAllowedActions = preview.allowedActions;
      });
      if (preview.errors.isNotEmpty) {
        context.appWarning('预览发现阻断异常，请先修正后重新预览');
      } else {
        context.appSuccess('计提预览已生成，请核对明细后提交');
      }
      await _loadRuns();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '计提预览失败，请重试');
    }
  }

  Future<void> _runPreviewAction(String action) async {
    final preview = _preview;
    if (preview == null || preview.errors.isNotEmpty) return;
    try {
      final response = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .postingAction(
            preview.runId,
            action,
            token: preview.token,
            expectedVersion: _workflowVersion,
          );
      if (!mounted) return;
      setState(() {
        _workflowVersion = response.version ?? _workflowVersion;
        _workflowAllowedActions = response.allowedActions;
        _workflowStatus = response.status.isEmpty
            ? switch (action) {
                'submit' => 'SUBMITTED',
                'approve' => 'APPROVED',
                'post' => 'POSTED',
                _ => _workflowStatus,
              }
            : response.status.toUpperCase();
      });
      context.appSuccess(switch (action) {
        'submit' => '过账批次已提交',
        'approve' => '过账批次已审批',
        'post' => '过账完成并已回查',
        _ => '操作成功',
      });
      await _loadRuns();
      await _loadPeriods();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '批次操作失败，请刷新后重试');
    }
  }

  Future<String?> _reasonDialog(String title) async {
    final controller = TextEditingController();
    String? errorText;
    final result = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 480,
            child: UtenInput(
              label: '原因 *',
              controller: controller,
              maxLines: 3,
              validator: (_) => errorText,
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            UtenButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) {
                  setDialogState(() => errorText = '请填写原因');
                  return;
                }
                Navigator.pop(dialogContext, value);
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _reverse(AssetPostingRun run) async {
    final reason = await _reasonDialog('冲销过账批次');
    if (reason == null || !mounted) return;
    try {
      await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .postingAction(
            run.id,
            'reverse',
            token: run.token,
            expectedVersion: run.version,
            reason: reason,
          );
      if (!mounted) return;
      context.appSuccess('冲销申请已提交，待复核与过账');
      await _loadRuns();
      await _loadPeriods();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '冲销失败，请重试');
    }
  }

  Future<void> _runHistoryAction(AssetPostingRun run, String action) async {
    try {
      await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .postingAction(
            run.id,
            action,
            token: run.token,
            expectedVersion: run.version,
          );
      if (!mounted) return;
      context.appSuccess(switch (action) {
        'submit' => '过账批次已提交',
        'approve' => '过账批次已审批',
        'post' => '过账完成并已回查',
        _ => '批次操作成功',
      });
      await _loadRuns();
      await _loadPeriods();
    } catch (error) {
      if (mounted) {
        context.appApiError(error, fallback: '批次操作失败，请刷新后重试');
      }
    }
  }

  Future<void> _periodAction(AssetPeriod period, String action) async {
    final reason = await _reasonDialog(
      action == 'close' ? '关闭资产期间' : '重新开放资产期间',
    );
    if (reason == null || !mounted) return;
    try {
      await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .periodAction(
            period.period,
            action,
            reason: reason,
            expectedVersion: period.version,
          );
      if (!mounted) return;
      context.appSuccess(action == 'close' ? '资产期间已关闭' : '资产期间已重新开放');
      await _loadPeriods();
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '期间操作失败，请重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final padding = constraints.maxWidth < UtenBreakpoints.mediumStart
            ? UtenSpacing.s12
            : UtenSpacing.s20;
        return ListView(
          key: const PageStorageKey('finance-asset-posting-panel'),
          padding: EdgeInsets.all(padding),
          children: [
            _previewCard(),
            if (_preview != null) ...[
              const SizedBox(height: UtenSpacing.s16),
              _previewResult(_preview!),
            ],
            const SizedBox(height: UtenSpacing.s20),
            _periodSection(),
            const SizedBox(height: UtenSpacing.s20),
            _runHistory(),
          ],
        );
      },
    );
  }

  Widget _previewCard() {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.xlAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '月度计提预览',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '必须先预览并核对异常与逐项金额，禁止一键计提。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          SegmentedButton<AssetPostingRunType>(
            segments: const [
              ButtonSegment(
                value: AssetPostingRunType.depreciation,
                label: Text('折旧'),
              ),
              ButtonSegment(
                value: AssetPostingRunType.amortization,
                label: Text('摊销'),
              ),
            ],
            selected: {_runType},
            onSelectionChanged: (values) => setState(() {
              _runType = values.single;
              _preview = null;
              _previewError = null;
              _workflowVersion = null;
            }),
          ),
          const SizedBox(height: UtenSpacing.s12),
          LayoutBuilder(
            builder: (context, constraints) {
              final field = UtenInput(
                key: const Key('finance-asset-posting-period'),
                label: '会计期间 *',
                hint: 'YYYY-MM',
                controller: _periodController,
                validator: (_) => _previewError,
                onChanged: (_) {
                  if (_previewError != null) {
                    setState(() => _previewError = null);
                  }
                },
              );
              final action = UtenActionButton(
                key: const Key('finance-asset-post-preview'),
                onAction: _previewPosting,
                icon: Icons.preview_outlined,
                label: const Text('生成预览'),
                loadingLabel: const Text('预览中…'),
              );
              if (constraints.maxWidth < UtenBreakpoints.mediumStart) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    field,
                    const SizedBox(height: UtenSpacing.s12),
                    action,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(child: field),
                  const SizedBox(width: UtenSpacing.s12),
                  action,
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _previewResult(AssetPostingPreview preview) {
    final theme = Theme.of(context);
    final hasErrors = preview.errors.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: hasErrors
            ? theme.colorScheme.errorContainer.withValues(alpha: 0.35)
            : theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.xlAll,
        border: Border.all(
          color: hasErrors
              ? theme.colorScheme.error
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: UtenSpacing.s20,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _metric('笔数', '${preview.count}'),
              _metric('总额', '¥ ${formatFinanceDecimal(preview.totalAmount)}'),
              _metric('警告', '${preview.warnings.length}'),
              _metric('阻断异常', '${preview.errors.length}'),
              financeAssetStatusBadge(_workflowStatus),
            ],
          ),
          if (preview.warnings.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _messages('警告', preview.warnings, theme.colorScheme.tertiary),
          ],
          if (preview.errors.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            _messages('阻断异常', preview.errors, theme.colorScheme.error),
          ],
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '逐项明细',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          _previewLines(preview.lines),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              if (widget.capabilities.canPost &&
                  preview.canSubmit &&
                  actionAllowed(_workflowAllowedActions, 'SUBMIT') &&
                  const {'PREVIEWED', ''}.contains(_workflowStatus))
                UtenActionButton(
                  key: const Key('finance-asset-post-submit'),
                  onAction: () => _runPreviewAction('submit'),
                  label: const Text('提交批次'),
                ),
              if (widget.capabilities.canApprove &&
                  preview.errors.isEmpty &&
                  actionAllowed(_workflowAllowedActions, 'APPROVE') &&
                  _workflowStatus == 'SUBMITTED')
                UtenActionButton(
                  key: const Key('finance-asset-post-approve'),
                  onAction: () => _runPreviewAction('approve'),
                  icon: Icons.verified_outlined,
                  label: const Text('审批批次'),
                ),
              if (widget.capabilities.canPost &&
                  preview.errors.isEmpty &&
                  actionAllowed(_workflowAllowedActions, 'POST') &&
                  _workflowStatus == 'APPROVED')
                UtenActionButton(
                  key: const Key('finance-asset-post-post'),
                  onAction: () => _runPreviewAction('post'),
                  icon: Icons.account_balance_outlined,
                  label: const Text('执行过账'),
                ),
              if (hasErrors)
                Text(
                  '存在阻断异常，提交与过账动作已锁定。',
                  key: const Key('finance-asset-post-blocked'),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(String label, String value) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  Widget _messages(
    String title,
    List<AssetPostingMessage> messages,
    Color color,
  ) {
    return Semantics(
      label: '$title，共 ${messages.length} 项',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: UtenRadius.lgAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title（${messages.length}）',
              style: TextStyle(color: color, fontWeight: FontWeight.w700),
            ),
            for (final message in messages)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: Text(
                  '• ${message.code == null ? '' : '${message.code}：'}${message.message}',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _previewLines(List<AssetPostingLine> lines) {
    if (lines.isEmpty) return const Text('暂无可计提项目');
    if (context.breakpoint.isCompact) {
      return Column(
        children: [
          for (final line in lines)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${line.code} ${line.name}'),
              subtitle: line.message == null ? null : Text(line.message!),
              trailing: Text(
                formatFinanceDecimal(line.amount),
                textAlign: TextAlign.right,
                style: const TextStyle(
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columns: const [
          DataColumn(label: Text('编号')),
          DataColumn(label: Text('名称')),
          DataColumn(label: Text('计提金额'), numeric: true),
          DataColumn(label: Text('状态')),
          DataColumn(label: Text('说明')),
        ],
        rows: [
          for (final line in lines)
            DataRow(
              cells: [
                DataCell(Text(line.code)),
                DataCell(Text(line.name)),
                DataCell(Text(formatFinanceDecimal(line.amount))),
                DataCell(financeAssetStatusBadge(line.status)),
                DataCell(Text(line.message ?? '—')),
              ],
            ),
        ],
      ),
    );
  }

  Widget _periodSection() {
    final theme = Theme.of(context);
    return _sectionShell(
      title: '资产期间',
      subtitle: '关闭或重开必须填写原因，并由专门权限控制。',
      child: _periodsLoading
          ? const Center(child: CircularProgressIndicator())
          : _periodsError != null
          ? _retry(_periodsError!, _loadPeriods)
          : _periods.isEmpty
          ? const Text('暂无资产期间')
          : Column(
              children: [
                for (final period in _periods)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      period.closed
                          ? Icons.lock_outline_rounded
                          : Icons.lock_open_rounded,
                      color: period.closed
                          ? theme.colorScheme.error
                          : theme.colorScheme.primary,
                    ),
                    title: Text(period.period),
                    subtitle: Text(
                      [period.closedAt, period.reason]
                          .whereType<String>()
                          .where((value) => value.isNotEmpty)
                          .join(' · '),
                    ),
                    trailing: Wrap(
                      spacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        financeAssetStatusBadge(period.status),
                        if (widget.capabilities.canManagePeriod &&
                            (!period.closed
                                ? actionAllowed(period.allowedActions, 'CLOSE')
                                : actionAllowed(
                                    period.allowedActions,
                                    'REOPEN',
                                  )))
                          UtenActionButton(
                            size: UtenActionButtonSize.small,
                            type: period.closed
                                ? UtenActionButtonType.secondary
                                : UtenActionButtonType.danger,
                            onAction: () => _periodAction(
                              period,
                              period.closed ? 'reopen' : 'close',
                            ),
                            label: Text(period.closed ? '重开' : '关闭'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _runHistory() {
    return _sectionShell(
      title: '过账批次历史',
      subtitle: '每次预览、审批、过账与冲销均保留可追溯记录。',
      child: _runsLoading
          ? const Center(child: CircularProgressIndicator())
          : _runsError != null
          ? _retry(_runsError!, _loadRuns)
          : _runs.isEmpty
          ? const Text('暂无过账批次')
          : Column(
              children: [
                for (final run in _runs)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      run.runType == AssetPostingRunType.depreciation
                          ? Icons.apartment_outlined
                          : Icons.calendar_month_outlined,
                    ),
                    title: Text('${run.period} · ${run.runType.label}'),
                    subtitle: Text(
                      '${run.itemCount} 笔 · ¥ ${formatFinanceDecimal(run.totalAmount)}${run.voucherNo == null ? '' : ' · 凭证 ${run.voucherNo}'}',
                    ),
                    trailing: Wrap(
                      spacing: UtenSpacing.s8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        financeAssetStatusBadge(run.status),
                        if (widget.capabilities.canPost &&
                            run.token?.isNotEmpty == true &&
                            actionAllowed(run.allowedActions, 'SUBMIT'))
                          UtenActionButton(
                            key: Key('finance-asset-history-submit-${run.id}'),
                            size: UtenActionButtonSize.small,
                            onAction: () => _runHistoryAction(run, 'submit'),
                            label: const Text('提交'),
                          ),
                        if (widget.capabilities.canApprove &&
                            actionAllowed(run.allowedActions, 'APPROVE'))
                          UtenActionButton(
                            key: Key('finance-asset-history-approve-${run.id}'),
                            size: UtenActionButtonSize.small,
                            onAction: () => _runHistoryAction(run, 'approve'),
                            label: const Text('审批'),
                          ),
                        if (widget.capabilities.canPost &&
                            actionAllowed(run.allowedActions, 'POST'))
                          UtenActionButton(
                            key: Key('finance-asset-history-post-${run.id}'),
                            size: UtenActionButtonSize.small,
                            onAction: () => _runHistoryAction(run, 'post'),
                            label: const Text('过账'),
                          ),
                        if (widget.capabilities.canPost &&
                            actionAllowed(run.allowedActions, 'REVERSE'))
                          UtenActionButton(
                            key: Key('finance-asset-history-reverse-${run.id}'),
                            type: UtenActionButtonType.danger,
                            size: UtenActionButtonSize.small,
                            onAction: () => _reverse(run),
                            label: const Text('冲销'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _sectionShell({
    required String title,
    required String subtitle,
    required Widget child,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.xlAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          child,
        ],
      ),
    );
  }

  Widget _retry(String message, VoidCallback retry) {
    return Row(
      children: [
        Expanded(child: Text(message)),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: retry,
          child: const Text('重试'),
        ),
      ],
    );
  }
}
