import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../models/production_material_analysis.dart';
import '../models/material_future_transfer.dart';
import '../repositories/production_repository.dart';

/// The exact successful stock-transfer intent, retained independently from
/// the current page's projection (which may be the receiving analysis).
class MaterialReallocationCompletion {
  const MaterialReallocationCompletion({
    required this.sourceAnalysisId,
    required this.sourceMaterialLineId,
    required this.targetAnalysisId,
    required this.targetMaterialLineId,
    required this.quantity,
    required this.sourceLabel,
    required this.idempotencyKey,
    this.futureTransfer = false,
  });
  final String sourceAnalysisId;
  final String sourceMaterialLineId;
  final String targetAnalysisId;
  final String targetMaterialLineId;
  final double quantity;
  final String sourceLabel;
  final String idempotencyKey;
  final bool futureTransfer;
}

/// 打开跨计划让料工作区。紧凑屏使用安全区底部抽屉，中大屏使用居中弹窗。
/// 返回服务端最新来源分析；取消返回 null。
Future<ProductionMaterialAnalysisView?> showMaterialReallocationDialog({
  required BuildContext context,
  required ProductionPlanRepository repository,
  required ProductionMaterialAnalysisView sourceAnalysis,
  required ProductionMaterialAnalysisMaterial sourceMaterial,
  required String sourceProductLabel,
  required String sourcePathLabel,
  required String Function(double?) qtyText,
  ValueChanged<ProductionMaterialAnalysisView>? onSourceRebased,
  ValueChanged<MaterialReallocationCompletion>? onCompleted,
  bool receiveIntoCurrent = false,
  bool futureTransfer = false,
}) {
  final body = _MaterialReallocationDialogBody(
    repository: repository,
    sourceAnalysis: sourceAnalysis,
    sourceMaterial: sourceMaterial,
    sourceProductLabel: sourceProductLabel,
    sourcePathLabel: sourcePathLabel,
    qtyText: qtyText,
    onSourceRebased: onSourceRebased,
    onCompleted: onCompleted,
    receiveIntoCurrent: receiveIntoCurrent || futureTransfer,
    futureTransfer: futureTransfer,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<ProductionMaterialAnalysisView>(
      context: context,
      useRootNavigator: true,
      useSafeArea: true,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(heightFactor: 0.94, child: body),
    );
  }
  return showDialog<ProductionMaterialAnalysisView>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      final height = (MediaQuery.sizeOf(dialogContext).height - 48)
          .clamp(420.0, 800.0)
          .toDouble();
      return Dialog(
        key: const Key('material-cross-reallocation-dialog'),
        insetPadding: utenDialogInsetPadding(dialogContext),
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: utenDialogWidth(dialogContext, 960),
          ),
          child: SizedBox(width: double.infinity, height: height, child: body),
        ),
      );
    },
  );
}

class _MaterialReallocationDialogBody extends StatefulWidget {
  const _MaterialReallocationDialogBody({
    required this.repository,
    required this.sourceAnalysis,
    required this.sourceMaterial,
    required this.sourceProductLabel,
    required this.sourcePathLabel,
    required this.qtyText,
    this.onSourceRebased,
    this.onCompleted,
    this.receiveIntoCurrent = false,
    this.futureTransfer = false,
  });

  final bool receiveIntoCurrent;
  final bool futureTransfer;
  final ProductionPlanRepository repository;
  final ProductionMaterialAnalysisView sourceAnalysis;
  final ProductionMaterialAnalysisMaterial sourceMaterial;
  final String sourceProductLabel;
  final String sourcePathLabel;
  final String Function(double?) qtyText;
  final ValueChanged<ProductionMaterialAnalysisView>? onSourceRebased;
  final ValueChanged<MaterialReallocationCompletion>? onCompleted;

  @override
  State<_MaterialReallocationDialogBody> createState() =>
      _MaterialReallocationDialogBodyState();
}

class _MaterialReallocationDialogBodyState
    extends State<_MaterialReallocationDialogBody> {
  final _formKey = GlobalKey<FormState>();
  final _searchController = TextEditingController();
  final _qtyController = TextEditingController();
  final _reasonController = TextEditingController();
  final _candidateScrollController = ScrollController();

  late ProductionMaterialAnalysisView _sourceAnalysis;
  late ProductionMaterialAnalysisMaterial _sourceMaterial;
  final List<MaterialReallocationEndpointCandidate> _candidates = [];
  MaterialReallocationEndpointCandidate? _target;
  int _page = 0;
  int _totalPages = 0;
  int _loadEpoch = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _submitting = false;
  bool _uncertain = false;
  bool _allowLate = false;
  bool get _locked => _submitting || _uncertain;
  bool _dirty = false;
  bool _allowPop = false;
  bool _showValidation = false;
  String? _loadError;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _sourceAnalysis = widget.sourceAnalysis;
    _sourceMaterial = widget.sourceMaterial;
    unawaited(_loadCandidates(reset: true));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _qtyController.dispose();
    _reasonController.dispose();
    _candidateScrollController.dispose();
    super.dispose();
  }

  String get _counterpartRole => widget.receiveIntoCurrent ? '供料计划' : '接受计划';
  String get _currentRole => widget.receiveIntoCurrent ? '接受计划' : '让出计划';

  double get _maxQty {
    final target = _target;
    if (target == null) return 0;
    return target.sourceLendableQty < target.shortageQty
        ? target.sourceLendableQty
        : target.shortageQty;
  }

  bool _sameCandidate(
    MaterialReallocationEndpointCandidate left,
    MaterialReallocationEndpointCandidate right,
  ) =>
      (left is MaterialFutureTransferSource &&
          right is MaterialFutureTransferSource
      ? left.sourceAllocationId == right.sourceAllocationId
      : left.analysisId == right.analysisId &&
            left.materialLineId == right.materialLineId);

  bool _candidateHasCas(MaterialReallocationEndpointCandidate candidate) =>
      candidate.analysisId.isNotEmpty &&
      candidate.materialLineId.isNotEmpty &&
      candidate.version > 0 &&
      candidate.fingerprint.isNotEmpty &&
      candidate.shortageQty > 0 &&
      candidate.sourceLendableQty > 0;

  Future<void> _loadCandidates({
    required bool reset,
    bool preserveSelection = false,
  }) async {
    if (_uncertain) return;
    final epoch = ++_loadEpoch;
    final nextPage = reset ? 1 : _page + 1;
    final selected = preserveSelection ? _target : null;
    setState(() {
      if (reset) {
        _loading = true;
        _loadError = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final page = widget.futureTransfer
          ? await widget.repository.materialFutureTransferSources(
              targetAnalysisId: _sourceAnalysis.analysisId,
              targetMaterialId: _sourceMaterial.materialLineId,
              page: nextPage,
              keyword: _searchController.text,
            )
          : widget.receiveIntoCurrent
          ? await widget.repository.materialCrossReallocationSources(
              targetAnalysisId: _sourceAnalysis.analysisId,
              targetMaterialLineId: _sourceMaterial.materialLineId,
              page: nextPage,
              keyword: _searchController.text,
            )
          : await widget.repository.materialCrossReallocationCandidates(
              sourceAnalysisId: _sourceAnalysis.analysisId,
              sourceMaterialLineId: _sourceMaterial.materialLineId,
              page: nextPage,
              keyword: _searchController.text,
            );
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        if (reset) _candidates.clear();
        for (final candidate in page.items) {
          final index = _candidates.indexWhere(
            (existing) => _sameCandidate(existing, candidate),
          );
          if (index >= 0) {
            _candidates[index] = candidate;
          } else {
            _candidates.add(candidate);
          }
        }
        _page = page.page;
        _totalPages = page.totalPages;
        _loading = false;
        _loadingMore = false;
        _loadError = null;
        if (selected != null) {
          final matches = _candidates.where(
            (candidate) => _sameCandidate(candidate, selected),
          );
          _target = matches.isEmpty ? null : matches.first;
          if (_target == null) {
            _submitError = '原$_counterpartRole已不再符合让料条件，请重新选择；数量和原因已保留。';
          }
        }
      });
    } catch (error) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _loadError = productionErrorMessage(
          error,
          fallback: '$_counterpartRole加载失败，请检查网络后重试',
        );
      });
    }
  }

  void _onSearchChanged(String _) {
    unawaited(_loadCandidates(reset: true));
  }

  void _selectCandidate(String? identity) {
    if (_locked) return;
    MaterialReallocationEndpointCandidate? selected;
    for (final candidate in _candidates) {
      if (_candidateIdentity(candidate) == identity) {
        selected = candidate;
        break;
      }
    }
    if (selected == null || !_candidateHasCas(selected)) return;
    setState(() {
      _target = selected;
      _dirty = true;
      _submitError = null;
      _qtyController.text = widget.qtyText(_maxQty);
      _allowLate = false;
    });
  }

  String _candidateIdentity(MaterialReallocationEndpointCandidate candidate) =>
      candidate is MaterialFutureTransferSource
      ? candidate.sourceAllocationId
      : '${candidate.analysisId}|${candidate.materialLineId}';

  String? _validateQty(String? raw) {
    final qty = double.tryParse(raw?.trim() ?? '');
    if (qty == null || !qty.isFinite || qty <= 0) return '请输入大于 0 的让料数量';
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw?.trim() ?? '')) {
      return '数量最多支持 4 位小数';
    }
    if (_target is MaterialFutureTransferSource &&
        (_target! as MaterialFutureTransferSource).lateOrUnknown &&
        !_allowLate) {
      return '请先明确接受晚到或交期未明确的供给';
    }
    if (qty > _maxQty) {
      return '最多可让 ${widget.qtyText(_maxQty)}'
          '(不超过服务端权威可让量和接受计划缺口)';
    }
    return null;
  }

  String? _validateReason(String? raw) {
    final reason = raw?.trim() ?? '';
    if (reason.length < 2) return '请填写至少 2 个字的业务原因';
    if (reason.length > 1000) return '业务原因不能超过 1000 个字';
    return null;
  }

  Future<void> _submit() async {
    final target = _target;
    if (target == null || _submitting) return;
    setState(() {
      _showValidation = true;
      _submitError = null;
    });
    if (_formKey.currentState?.validate() != true) return;
    final qty = double.parse(_qtyController.text.trim());
    final reason = _reasonController.text.trim();
    final key = businessIdempotencyKey(
      widget.futureTransfer
          ? 'material-analysis-private-future-transfer'
          : widget.receiveIntoCurrent
          ? 'material-analysis-cross-reallocation-receive'
          : 'material-analysis-cross-reallocation',
      [
        _sourceAnalysis.analysisId,
        _sourceAnalysis.version,
        _sourceAnalysis.fingerprint,
        _sourceMaterial.materialLineId,
        target.analysisId,
        target.version,
        target.fingerprint,
        target.materialLineId,
        if (target is MaterialFutureTransferSource) target.sourceAllocationId,
        if (widget.futureTransfer) _allowLate,
        qty,
        reason,
      ].join('|'),
    );
    setState(() => _submitting = true);
    try {
      final view = widget.futureTransfer
          ? await widget.repository.createMaterialFutureTransfer(
              targetAnalysis: _sourceAnalysis,
              targetMaterialId: _sourceMaterial.materialLineId,
              source: target as MaterialFutureTransferSource,
              qty: qty,
              allowLateSupply: _allowLate,
              reason: reason,
              idempotencyKey: key,
            )
          : widget.receiveIntoCurrent
          ? await widget.repository.acceptMaterialCrossReallocation(
              targetAnalysis: _sourceAnalysis,
              targetMaterialLineId: _sourceMaterial.materialLineId,
              source: target as MaterialCrossReallocationSourceCandidate,
              qty: qty,
              reason: reason,
              idempotencyKey: key,
            )
          : await widget.repository.createMaterialCrossReallocation(
              sourceAnalysis: _sourceAnalysis,
              target: target as MaterialCrossReallocationCandidate,
              sourceMaterialLineId: _sourceMaterial.materialLineId,
              qty: qty,
              reason: reason,
              idempotencyKey: key,
            );
      if (!mounted) return;
      widget.onCompleted?.call(
        MaterialReallocationCompletion(
          sourceAnalysisId: widget.receiveIntoCurrent
              ? target.analysisId
              : _sourceAnalysis.analysisId,
          sourceMaterialLineId: widget.receiveIntoCurrent
              ? target.materialLineId
              : _sourceMaterial.materialLineId,
          targetAnalysisId: widget.receiveIntoCurrent
              ? _sourceAnalysis.analysisId
              : target.analysisId,
          targetMaterialLineId: widget.receiveIntoCurrent
              ? _sourceMaterial.materialLineId
              : target.materialLineId,
          quantity: qty,
          sourceLabel: widget.receiveIntoCurrent
              ? target.displayAnalysisLabel
              : widget.sourceProductLabel,
          idempotencyKey: key,
          futureTransfer: widget.futureTransfer,
        ),
      );
      _finish(view);
    } catch (error) {
      if (!mounted) return;
      if (error is ApiException && error.code == 'CONFLICT') {
        _uncertain = false;
        await _recoverConflict(error);
      } else {
        setState(() {
          _submitting = false;
          _uncertain =
              error is! ApiException ||
              error is NetworkException ||
              error is NetworkTimeoutException ||
              error.code == 'INTERNAL' ||
              (error.httpStatus ?? 0) >= 500;
          _submitError = _uncertain
              ? '暂未确认调拨结果，原来源、数量和请求已保留，请同键重试确认。'
              : productionErrorMessage(error, fallback: '跨计划让料失败，请重试');
        });
      }
    }
  }

  Future<void> _recoverConflict(ApiException conflict) async {
    try {
      final latest = await widget.repository.materialAnalysisDetail(
        _sourceAnalysis.analysisId,
      );
      ProductionMaterialAnalysisMaterial? source;
      for (final material in latest.materials) {
        if (material.materialLineId == _sourceMaterial.materialLineId) {
          source = material;
          break;
        }
      }
      if (source == null) {
        throw StateError('source material disappeared');
      }
      _sourceAnalysis = latest;
      _sourceMaterial = source;
      widget.onSourceRebased?.call(latest);
      await _loadCandidates(reset: true, preserveSelection: true);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = '库存或计划状态已变化，已加载最新候选；数量和原因已保留，请核对后再次确认。';
      });
    } catch (reloadError) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError =
            '${conflict.message}；加载最新计划失败：'
            '${productionErrorMessage(reloadError, fallback: '请稍后重试')}';
      });
    }
  }

  Future<void> _requestClose() async {
    if (_locked) return;
    if (_dirty) {
      final discard = await UtenDialog.show(
        context,
        title: '放弃未提交的让料内容？',
        content: const Text('已填写的接受计划、数量和业务原因不会保存。'),
        confirmLabel: '放弃并关闭',
      );
      if (discard != true || !mounted) return;
    }
    _finish();
  }

  void _finish([ProductionMaterialAnalysisView? result]) {
    if (!mounted) return;
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop(result);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<ProductionMaterialAnalysisView?>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_requestClose());
      },
      child: Material(
        key: const Key('material-cross-reallocation-sheet'),
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.xxlAll,
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          child: Column(
            children: [
              _header(theme),
              const Divider(height: 1),
              _sourceSummary(theme),
              const Divider(height: 1),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final horizontal = constraints.maxWidth >= 760;
                    final candidates = _candidatePanel(theme);
                    final form = _formPanel(theme);
                    if (horizontal) {
                      return Row(
                        children: [
                          Expanded(flex: 11, child: candidates),
                          const VerticalDivider(width: 1),
                          Expanded(flex: 9, child: form),
                        ],
                      );
                    }
                    return Column(
                      children: [
                        Expanded(flex: 5, child: candidates),
                        const Divider(height: 1),
                        Expanded(flex: 6, child: form),
                      ],
                    );
                  },
                ),
              ),
              const Divider(height: 1),
              _actions(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(
      UtenSpacing.s20,
      UtenSpacing.s12,
      UtenSpacing.s8,
      UtenSpacing.s12,
    ),
    child: Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.futureTransfer ? '调整其他计划专属在途' : '跨计划让料',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                widget.futureTransfer
                    ? '专属份额改给本计划；原计划缺口另行补供，未实收前不计现货。'
                    : '让出后原计划进入优先待补；接受计划无需返还。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: '关闭跨计划让料',
          onPressed: _locked ? null : _requestClose,
          icon: const Icon(Icons.close_rounded),
        ),
      ],
    ),
  );

  Widget _sourceSummary(ThemeData theme) => Semantics(
    container: true,
    label:
        '$_currentRole：${widget.sourceProductLabel}，'
        '${_sourceMaterial.goodsName ?? _sourceMaterial.goodsCode ?? '物料'}，'
        '${widget.receiveIntoCurrent ? '当前缺口' : '现货覆盖'} '
        '${widget.qtyText(widget.receiveIntoCurrent ? _sourceMaterial.shortageQty : _sourceMaterial.allocatedAvailableQty)}',
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      color: theme.colorScheme.surfaceContainerLow,
      child: Wrap(
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s4,
        children: [
          Text(
            '$_currentRole：${widget.sourceProductLabel}',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          Text('路径：${widget.sourcePathLabel}'),
          Text(
            '物料：${_sourceMaterial.goodsName ?? _sourceMaterial.goodsCode ?? '未命名物料'}',
          ),
          Text(
            widget.futureTransfer
                ? '本计划物理缺口：${widget.qtyText(_sourceMaterial.shortageQty)}；尚需安排 ${widget.qtyText(_sourceMaterial.additionalSupplyRecommendedQty)}'
                : widget.receiveIntoCurrent
                ? '本计划缺口：${widget.qtyText(_sourceMaterial.shortageQty)}'
                : '现货覆盖：${widget.qtyText(_sourceMaterial.allocatedAvailableQty)}',
          ),
        ],
      ),
    ),
  );

  Widget _candidatePanel(ThemeData theme) => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IgnorePointer(
          // 提交期间不接受新的关键词检索（原 TextField enabled: !_submitting 语义，
          // UtenSearchBar 无 enabled 参数，用指针拦截保持等价）。
          ignoring: _locked,
          child: UtenSearchBar(
            key: const Key('cross-reallocation-search'),
            controller: _searchController,
            hint: '订单号、来源号或产品名称',
            onChanged: _onSearchChanged,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(child: _candidateContent(theme)),
      ],
    ),
  );

  Widget _candidateContent(ThemeData theme) {
    if (_loading) {
      return const Center(
        key: Key('cross-reallocation-candidates-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (_loadError != null) {
      return _messageState(
        theme,
        key: const Key('cross-reallocation-candidates-error'),
        icon: Icons.cloud_off_rounded,
        text: _loadError!,
        action: UtenButton(
          key: const Key('cross-reallocation-candidates-retry'),
          size: UtenButtonSize.large,
          type: UtenButtonType.tonal,
          onPressed: () => _loadCandidates(reset: true),
          child: const Text('重新加载'),
        ),
      );
    }
    if (_candidates.isEmpty) {
      return _messageState(
        theme,
        key: const Key('cross-reallocation-candidates-empty'),
        icon: Icons.inventory_2_outlined,
        text: widget.futureTransfer
            ? '没有可调整的其他计划专属在途。仅可选尚未实收、仍有可调整份额的正式来源；公共余量请使用“采用公共在途”。'
            : widget.receiveIntoCurrent
            ? '没有可调入的其它计划现货。\n'
                  '供料计划须在同主仓范围、同货品/颜色/单位，持有尚未正式预留的原始合格库存；已有未补齐让料或分析内调配的节点须先完成或撤销。\n'
                  '已正式预留、已领或在制的料受保护。若旧计划尚未领料，可从原计划详情按原取消流程解除正式占用，权益恢复后再调入。已下达但仍等待物料的计划可以参与让料。'
            : '没有可接受这批料的其它计划。\n'
                  '候选必须同主仓范围、同货品/颜色/单位，并且仍有真实缺口。',
      );
    }
    return RadioGroup<String>(
      groupValue: _target == null ? null : _candidateIdentity(_target!),
      onChanged: (value) {
        if (!_locked) _selectCandidate(value);
      },
      child: ListView.separated(
        key: const Key('cross-reallocation-candidates-list'),
        controller: _candidateScrollController,
        itemCount: _candidates.length + (_page < _totalPages ? 1 : 0),
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          if (index == _candidates.length) {
            return Padding(
              padding: const EdgeInsets.all(UtenSpacing.s8),
              child: UtenButton(
                key: const Key('cross-reallocation-load-more'),
                size: UtenButtonSize.large,
                type: UtenButtonType.ghost,
                isLoading: _loadingMore,
                isExpanded: true,
                onPressed: _loadingMore || _locked
                    ? null
                    : () => _loadCandidates(reset: false),
                child: Text('加载更多$_counterpartRole'),
              ),
            );
          }
          final candidate = _candidates[index];
          final enabled = _candidateHasCas(candidate) && !_locked;
          final details = [
            if (candidate.productLabel?.trim().isNotEmpty == true)
              candidate.productLabel!.trim(),
            if (candidate.pathLabel?.trim().isNotEmpty == true)
              candidate.pathLabel!.trim(),
            '${widget.receiveIntoCurrent ? '该计划' : '本计划'}可让 ${widget.qtyText(candidate.sourceLendableQty)}',
            '${widget.receiveIntoCurrent ? '本计划' : '对方'}${widget.futureTransfer ? '尚需安排' : '缺'} ${widget.qtyText(candidate.shortageQty)}',
            if (candidate.deliveryDate?.trim().isNotEmpty == true)
              '交期 ${candidate.deliveryDate}',
            if (candidate.warehouseName?.trim().isNotEmpty == true)
              candidate.warehouseName!.trim(),
            if (candidate is MaterialFutureTransferSource) candidate.stageLabel,
            if (candidate is MaterialFutureTransferSource &&
                candidate.lateOrUnknown)
              '晚到或交期待确认，须明确接受',
          ];
          return Semantics(
            selected: _target != null && _sameCandidate(_target!, candidate),
            label: '${candidate.displayAnalysisLabel}，${details.join('，')}',
            child: RadioListTile<String>(
              key: ValueKey(
                candidate is MaterialFutureTransferSource
                    ? 'future-transfer-candidate-${candidate.sourceAllocationId}'
                    : 'cross-reallocation-candidate-${candidate.analysisId}-${candidate.materialLineId}',
              ),
              value: _candidateIdentity(candidate),
              enabled: enabled,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s8,
                vertical: UtenSpacing.s4,
              ),
              title: Text(
                candidate.displayAnalysisLabel,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              subtitle: Text(
                _candidateHasCas(candidate)
                    ? details.join(' · ')
                    : '候选快照已失效，请重新加载',
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _formPanel(ThemeData theme) {
    final target = _target;
    if (target == null) {
      return _messageState(
        theme,
        key: const Key('cross-reallocation-target-prompt'),
        icon: Icons.touch_app_outlined,
        text: '先选择一份$_counterpartRole，再填写让料数量和业务原因。',
      );
    }
    final parsedQty = double.tryParse(_qtyController.text.trim());
    return Form(
      key: _formKey,
      autovalidateMode: _showValidation
          ? AutovalidateMode.onUserInteraction
          : AutovalidateMode.disabled,
      child: ListView(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        children: [
          Text(
            _counterpartRole,
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            target.displayAnalysisLabel,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (target.productLabel?.trim().isNotEmpty == true)
            Text(target.productLabel!, style: theme.textTheme.bodyMedium),
          const SizedBox(height: UtenSpacing.s12),
          if (target is MaterialFutureTransferSource && target.lateOrUnknown)
            CheckboxListTile(
              key: const Key('future-transfer-accept-late'),
              contentPadding: EdgeInsets.zero,
              title: const Text('接受晚到或交期未明确供给'),
              value: _allowLate,
              onChanged: _locked
                  ? null
                  : (value) => setState(() {
                      _allowLate = value ?? false;
                      _dirty = true;
                    }),
            ),
          TextFormField(
            errorBuilder: utenTextFieldErrorBuilder,
            key: const Key('cross-reallocation-qty'),
            controller: _qtyController,
            ignorePointers: false,
            enabled: !_locked,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textInputAction: TextInputAction.next,
            validator: _validateQty,
            onChanged: (_) => setState(() {
              _dirty = true;
              _submitError = null;
            }),
            decoration: UtenInputDecoration(
              InputDecoration(
                label: fieldLabel(
                  widget.futureTransfer ? '调整在途份额' : '让料数量',
                  theme,
                  info:
                      '服务端可让 ${widget.qtyText(target.sourceLendableQty)} · '
                      '接受计划缺 ${widget.qtyText(target.shortageQty)} · 最多 ${widget.qtyText(_maxQty)}',
                ),
                suffixText: _sourceMaterial.unitName,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          TextFormField(
            errorBuilder: utenTextFieldErrorBuilder,
            key: const Key('cross-reallocation-reason'),
            controller: _reasonController,
            ignorePointers: false,
            enabled: !_locked,
            minLines: 2,
            maxLines: 4,
            maxLength: 1000,
            validator: _validateReason,
            onChanged: (_) => setState(() {
              _dirty = true;
              _submitError = null;
            }),
            decoration: UtenInputDecoration(
              InputDecoration(
                label: fieldLabel(
                  '业务原因(必填)',
                  theme,
                  info: '例如：客户订单加急，本批现货先给该计划。',
                ),
                alignLabelWithHint: true,
              ),
            ),
          ),
          if (parsedQty != null && parsedQty > 0) ...[
            const SizedBox(height: UtenSpacing.s8),
            Semantics(
              key: const Key('cross-reallocation-impact'),
              container: true,
              label: widget.futureTransfer
                  ? '原计划减少专属在途 ${widget.qtyText(parsedQty)}，接受计划新增未来供给，尚未实收、不计现货或开工量'
                  : '让料影响：${widget.receiveIntoCurrent ? '供料计划' : '当前计划'}优先待补 ${widget.qtyText(parsedQty)}，'
                        '接受计划缺口减少 ${widget.qtyText(parsedQty)}，无需返还',
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: UtenRadius.mdAll,
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '确认后的影响',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '• ${widget.receiveIntoCurrent ? '供料计划' : '当前计划'}让出 ${widget.qtyText(parsedQty)}，并标记优先待补。',
                    ),
                    Text(
                      widget.futureTransfer
                          ? '• 接受计划新增已安排未来供给 ${widget.qtyText(parsedQty)}；物理缺口在实际合格入库后再减少。'
                          : '• 接受计划缺口减少 ${widget.qtyText(parsedQty)}，无需返还。',
                    ),
                    Text(
                      widget.futureTransfer
                          ? '• 未实收份额可按正式记录撤销；原计划需补供时另行确认，不自动下单。'
                          : '• 双方后续符合条件的合格入库，会优先补齐让出计划。',
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (_submitError != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Semantics(
              liveRegion: true,
              child: Text(
                _submitError!,
                key: const Key('cross-reallocation-submit-error'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _messageState(
    ThemeData theme, {
    required Key key,
    required IconData icon,
    required String text,
    Widget? action,
  }) => Center(
    key: key,
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            text,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (action != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            action,
          ],
        ],
      ),
    ),
  );

  Widget _actions(ThemeData theme) => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s12),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 520;
        final cancel = UtenButton(
          key: const Key('cross-reallocation-cancel'),
          size: UtenButtonSize.large,
          type: UtenButtonType.ghost,
          isExpanded: compact,
          onPressed: _locked ? null : _requestClose,
          child: const Text('取消'),
        );
        final confirm = UtenButton(
          key: const Key('cross-reallocation-confirm'),
          size: UtenButtonSize.large,
          isExpanded: compact,
          isLoading: _submitting,
          onPressed: _target == null || _submitting ? null : _submit,
          child: Text(
            _uncertain
                ? '重试确认调拨'
                : widget.futureTransfer
                ? '确认调整在途'
                : '确认让料',
          ),
        );
        if (compact) {
          return Row(
            children: [
              Expanded(child: cancel),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(child: confirm),
            ],
          );
        }
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            cancel,
            const SizedBox(width: UtenSpacing.s8),
            confirm,
          ],
        );
      },
    ),
  );
}
