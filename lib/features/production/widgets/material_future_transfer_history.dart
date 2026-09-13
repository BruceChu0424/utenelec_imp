import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/material_future_transfer.dart';
import '../models/production_material_analysis.dart';
import '../repositories/production_repository.dart';

/// Exact private future allocations. Public surplus claims remain independent.
class MaterialFutureTransferHistory extends StatefulWidget {
  const MaterialFutureTransferHistory({
    super.key,
    required this.repository,
    required this.analysisId,
    required this.materialId,
    required this.revision,
    required this.canWrite,
    required this.canReplenish,
    required this.onChanged,
    required this.onReplenish,
  });
  final ProductionPlanRepository repository;
  final String analysisId;
  final String materialId;
  final int revision;
  final bool canWrite;
  final bool canReplenish;
  final ValueChanged<ProductionMaterialAnalysisView> onChanged;
  final ValueChanged<MaterialFutureTransferRecord> onReplenish;
  @override
  State<MaterialFutureTransferHistory> createState() =>
      _MaterialFutureTransferHistoryState();
}

class _MaterialFutureTransferHistoryState
    extends State<MaterialFutureTransferHistory> {
  List<MaterialFutureTransferRecord>? _records;
  String? _error;
  bool _loading = true;
  int _epoch = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MaterialFutureTransferHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.analysisId != widget.analysisId ||
        oldWidget.materialId != widget.materialId) {
      _records = null;
    }
    if (oldWidget.analysisId != widget.analysisId ||
        oldWidget.materialId != widget.materialId ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  Future<void> _load() async {
    final epoch = ++_epoch;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final records = await widget.repository.materialFutureTransfers(
        analysisId: widget.analysisId,
        materialId: widget.materialId,
      );
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _records = records;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || epoch != _epoch) return;
      setState(() {
        _error = productionErrorMessage(error, fallback: '专属在途调拨进度加载失败，当前进度未知');
        _loading = false;
      });
    }
  }

  Future<void> _cancel(MaterialFutureTransferRecord record) async {
    final result = await showDialog<ProductionMaterialAnalysisView>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _CancelFutureTransferDialog(
        repository: widget.repository,
        analysisId: widget.analysisId,
        record: record,
      ),
    );
    if (!mounted || result == null) return;
    widget.onChanged(result);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: UtenSpacing.s8),
        Text('专属在途调拨记录', style: theme.textTheme.titleSmall),
        const Text('只调整已安排的未来供给；实际合格入库后才减少物理缺口。'),
        if (_loading) const LinearProgressIndicator(),
        if (_error != null)
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(_error!),
              UtenButton(
                key: const Key('future-transfer-history-retry'),
                type: UtenButtonType.ghost,
                onPressed: _load,
                child: const Text('重试查询'),
              ),
            ],
          )
        else if (!_loading && _records?.isEmpty == true)
          const Text('暂无专属在途调拨记录'),
        for (final record in _records ?? <MaterialFutureTransferRecord>[])
          Container(
            key: ValueKey('future-transfer-record-${record.id}'),
            margin: const EdgeInsets.only(top: UtenSpacing.s8),
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              borderRadius: UtenRadius.smAll,
              color: record.outbound
                  ? theme.colorScheme.primaryContainer.withValues(alpha: .35)
                  : theme.colorScheme.surfaceContainerLow,
              border: Border.all(
                color: record.outbound
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${record.outbound ? '已让出专属在途' : '已调入专属在途'} ${_qty(record.qty)} · ${record.statusLabel}',
                  style: theme.textTheme.labelLarge,
                ),
                Text(
                  '${record.sourceLabel ?? '原供料计划'} → ${record.targetLabel ?? '接受计划'}',
                ),
                Text(
                  '已实收 ${_qty(record.receivedQty)} · 待实收 ${_qty(record.remainingQty)} · 已撤销 ${_qty(record.cancelledQty)}',
                ),
                Text('预计到货：${record.expectedDate ?? '交期尚未明确'}'),
                if (record.sourceSupplyShortfallQty > 0 ||
                    record.supplyWarning?.isNotEmpty == true)
                  Text(
                    record.supplyWarning ??
                        '原供给尚缺 ${_qty(record.sourceSupplyShortfallQty)}，请核对补供或撤销未实收份额',
                    key: ValueKey(
                      'future-transfer-supply-warning-${record.id}',
                    ),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (record.reason?.isNotEmpty == true)
                  Text('业务原因：${record.reason}'),
                if (!record.canCancel &&
                    record.blockedReason?.isNotEmpty == true)
                  Text('当前不可撤销：${record.blockedReason}'),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    if (widget.canReplenish && record.qty > record.cancelledQty)
                      UtenButton(
                        key: ValueKey('future-transfer-replenish-${record.id}'),
                        type: UtenButtonType.tonal,
                        onPressed: _loading || _error != null
                            ? null
                            : () => widget.onReplenish(record),
                        child: Text(record.outbound ? '继续补供' : '为原计划补供'),
                      ),
                    if (widget.canWrite &&
                        record.canCancel &&
                        record.maxCancelableQty > 0 &&
                        _error == null &&
                        !_loading)
                      UtenButton(
                        key: ValueKey('future-transfer-cancel-${record.id}'),
                        type: UtenButtonType.ghost,
                        onPressed: () => _cancel(record),
                        child: const Text('撤销未实收份额'),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}

String _qty(double value) =>
    value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');

class _CancelFutureTransferDialog extends StatefulWidget {
  const _CancelFutureTransferDialog({
    required this.repository,
    required this.analysisId,
    required this.record,
  });
  final ProductionPlanRepository repository;
  final String analysisId;
  final MaterialFutureTransferRecord record;
  @override
  State<_CancelFutureTransferDialog> createState() =>
      _CancelFutureTransferDialogState();
}

class _CancelFutureTransferDialogState
    extends State<_CancelFutureTransferDialog> {
  late MaterialFutureTransferRecord _record;
  late final TextEditingController _quantity;
  final _reason = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _key = const Uuid().v4();
  String? _error;
  bool _saving = false;
  bool _uncertain = false;
  bool _needsReview = false;
  bool _allowPop = false;
  bool _acceptPublicRelease = false;
  double get _requestedQty => double.tryParse(_quantity.text.trim()) ?? 0;
  double get _restoreQty =>
      _requestedQty.clamp(0, _record.maxRestoreToSourceQty);
  double get _publicQty => double.parse(
    (_requestedQty - _restoreQty)
        .clamp(0, _requestedQty > 0 ? _requestedQty : 0)
        .toStringAsFixed(4),
  );
  bool get _locked => _saving || _uncertain;
  @override
  void initState() {
    super.initState();
    _record = widget.record;
    _quantity = TextEditingController(text: _qty(_record.maxCancelableQty));
  }

  @override
  void dispose() {
    _quantity.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _close([ProductionMaterialAnalysisView? view]) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(view);
    });
  }

  Future<void> _refresh() async {
    if (_locked) return;
    setState(() {
      _saving = true;
      _needsReview = true;
    });
    try {
      final records = await widget.repository.materialFutureTransfers(
        analysisId: widget.analysisId,
      );
      final record = records.where((r) => r.id == _record.id).firstOrNull;
      if (record == null) throw StateError('调拨记录已不可见，请返回计划重新核对');
      if (!mounted) return;
      setState(() {
        _record = record;
        _acceptPublicRelease = false;
        _needsReview = false;
        _key = const Uuid().v4();
        _error = record.canCancel
            ? '双方最新状态已加载，数量和原因已保留，请核对后重新确认。'
            : record.blockedReason ?? '当前份额已不可撤销';
      });
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = productionErrorMessage(
            error,
            fallback: '当前状态加载失败，请重试查询',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _submit() async {
    if (_saving ||
        _needsReview ||
        !_record.canCancel ||
        _formKey.currentState?.validate() != true) {
      return;
    }
    if (_publicQty > 0 && !_acceptPublicRelease) {
      setState(() => _error = '请明确确认：超出原计划当前缺口的份额释放为公共供给。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final view = await widget.repository.cancelMaterialFutureTransfer(
        analysisId: widget.analysisId,
        transfer: _record,
        qty: double.parse(_quantity.text.trim()),
        reason: _reason.text.trim(),
        idempotencyKey: _key,
        acceptPublicRelease: _publicQty > 0 && _acceptPublicRelease,
      );
      if (mounted) _close(view);
    } catch (error) {
      if (!mounted) return;
      final uncertain =
          error is! ApiException ||
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'INTERNAL' ||
          (error.httpStatus ?? 0) >= 500;
      setState(() {
        _saving = false;
        _uncertain = uncertain;
        _needsReview = !uncertain;
        _error = uncertain
            ? '撤销结果尚未确认，已保留原请求；请重试确认，避免重复撤销。'
            : productionErrorMessage(error, fallback: '当前状态已变化，请重新核对');
      });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_locked) _close();
    },
    child: AlertDialog(
      title: const Text('撤销未实收份额'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${_record.sourceLabel ?? '原供料计划'} ← ${_record.targetLabel ?? '接受计划'}',
                ),
                Text(
                  '已实收 ${_qty(_record.receivedQty)} 不可撤销；当前可撤销 ${_qty(_record.maxCancelableQty)}。两边供给归属与公共余量以正式回执为准。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextFormField(
                  key: const Key('future-transfer-cancel-qty'),
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _quantity,
                  onChanged: (_) => setState(() {}),
                  enabled: !_locked,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const UtenInputDecoration(
                    InputDecoration(labelText: '本次撤销数量'),
                  ),
                  validator: (raw) {
                    final value = double.tryParse(raw?.trim() ?? '');
                    if (value == null ||
                        !value.isFinite ||
                        value <= 0 ||
                        !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw!.trim())) {
                      return '请输入大于 0、最多 4 位小数的数量';
                    }
                    if (value > _record.maxCancelableQty + .000001) {
                      return '不能超过当前可撤销净量 ${_qty(_record.maxCancelableQty)}';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  '本次恢复原计划 ${_qty(_restoreQty)} · 释放公共供给 ${_qty(_publicQty)}',
                ),
                if (_publicQty > 0)
                  CheckboxListTile(
                    key: const Key('future-transfer-cancel-public-release'),
                    contentPadding: EdgeInsets.zero,
                    value: _acceptPublicRelease,
                    onChanged: _locked
                        ? null
                        : (value) => setState(
                            () => _acceptPublicRelease = value == true,
                          ),
                    title: const Text('确认超出原计划缺口的部分释放为公共供给'),
                    subtitle: const Text(
                      '保留原计划已有补单；尚未实收部分成为公共待入库供给，实际合格入库后才成为公共现货。',
                    ),
                  ),
                const SizedBox(height: UtenSpacing.s12),
                TextFormField(
                  key: const Key('future-transfer-cancel-reason'),
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _reason,
                  enabled: !_locked,
                  maxLines: 3,
                  decoration: const UtenInputDecoration(
                    InputDecoration(labelText: '撤销原因'),
                  ),
                  validator: (raw) =>
                      (raw?.trim().length ?? 0) < 2 ||
                          (raw?.trim().length ?? 0) > 1000
                      ? '请填写 2 至 1000 字的业务原因'
                      : null,
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s12),
                    child: Text(_error!),
                  ),
                if (_needsReview)
                  UtenButton(
                    key: const Key('future-transfer-cancel-refresh'),
                    type: UtenButtonType.ghost,
                    onPressed: _locked ? null : _refresh,
                    child: const Text('重新核对最新状态'),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        UtenButton(
          key: const Key('future-transfer-cancel-close'),
          type: UtenButtonType.ghost,
          onPressed: _locked ? null : _close,
          child: const Text('暂不撤销'),
        ),
        UtenButton(
          key: const Key('future-transfer-cancel-confirm'),
          isLoading: _saving,
          onPressed: _saving || _needsReview || !_record.canCancel
              ? null
              : _submit,
          child: Text(_uncertain ? '重试确认撤销' : '确认撤销'),
        ),
      ],
    ),
  );
}
