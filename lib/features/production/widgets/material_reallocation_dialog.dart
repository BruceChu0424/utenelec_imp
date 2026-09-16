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

/// 打开跨计划调拨工作区。紧凑屏使用安全区底部抽屉，中大屏使用居中弹窗。
///
/// 让出模式（默认）为当前计划的现货寻找接受方；调入模式检索其它计划的
/// 现货（receiveIntoCurrent）或专属在途（futureTransfer）。加载后自动
/// 匹配最合适的来源并预填数量；在途模式可多选来源逐笔提交（现货受
/// 「一个节点仅一条未补齐关系」约束，保持单选）。返回服务端最新来源
/// 分析；取消返回 null。
Future<ProductionMaterialAnalysisView?> showMaterialReallocationDialog({
  required BuildContext context,
  required ProductionPlanRepository repository,
  required ProductionMaterialAnalysisView sourceAnalysis,
  required ProductionMaterialAnalysisMaterial sourceMaterial,
  required String sourceProductLabel,
  required String Function(double?) qtyText,
  ValueChanged<ProductionMaterialAnalysisView>? onSourceRebased,
  ValueChanged<MaterialReallocationCompletion>? onCompleted,
  bool receiveIntoCurrent = false,
  bool futureTransfer = false,
  void Function(MaterialReallocationEndpointCandidate candidate)?
  onOpenSourcePlan,
  void Function(MaterialReallocationEndpointCandidate candidate)?
  onOpenSourceDocument,
}) {
  final body = _MaterialReallocationDialogBody(
    repository: repository,
    sourceAnalysis: sourceAnalysis,
    sourceMaterial: sourceMaterial,
    sourceProductLabel: sourceProductLabel,
    qtyText: qtyText,
    onSourceRebased: onSourceRebased,
    onCompleted: onCompleted,
    receiveIntoCurrent: receiveIntoCurrent || futureTransfer,
    futureTransfer: futureTransfer,
    onOpenSourcePlan: onOpenSourcePlan,
    onOpenSourceDocument: onOpenSourceDocument,
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
    required this.qtyText,
    this.onSourceRebased,
    this.onCompleted,
    this.receiveIntoCurrent = false,
    this.futureTransfer = false,
    this.onOpenSourcePlan,
    this.onOpenSourceDocument,
  });

  final bool receiveIntoCurrent;
  final bool futureTransfer;
  final ProductionPlanRepository repository;
  final ProductionMaterialAnalysisView sourceAnalysis;
  final ProductionMaterialAnalysisMaterial sourceMaterial;
  final String sourceProductLabel;
  final String Function(double?) qtyText;
  final ValueChanged<ProductionMaterialAnalysisView>? onSourceRebased;
  final ValueChanged<MaterialReallocationCompletion>? onCompleted;
  final void Function(MaterialReallocationEndpointCandidate candidate)?
  onOpenSourcePlan;
  final void Function(MaterialReallocationEndpointCandidate candidate)?
  onOpenSourceDocument;

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
  final Map<String, MaterialReallocationEndpointCandidate> _byIdentity = {};
  MaterialReallocationEndpointCandidate? _target;

  /// 在途多选：已勾选来源及其数量输入（按候选标识索引）。
  final Set<String> _selectedIds = {};
  final Map<String, TextEditingController> _selectedQtyControllers = {};

  int _page = 0;
  int _totalPages = 0;
  int _spotPage = 0;
  int _spotTotalPages = 0;
  int _futurePage = 0;
  int _futureTotalPages = 0;
  int _loadEpoch = 0;
  bool _loading = true;
  bool _loadingMore = false;
  bool _submitting = false;
  bool _uncertain = false;
  bool get _locked => _submitting || _uncertain;
  bool _dirty = false;
  bool _allowPop = false;
  bool _showValidation = false;
  int _batchDone = 0;
  int _batchTotal = 0;
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
    for (final controller in _selectedQtyControllers.values) {
      controller.dispose();
    }
    _candidateScrollController.dispose();
    super.dispose();
  }

  String get _counterpartRole => widget.receiveIntoCurrent ? '供料计划' : '接受计划';
  String get _currentRole => widget.receiveIntoCurrent ? '接受计划' : '让出计划';
  bool get _multiSelect => widget.futureTransfer;

  double get _maxQty {
    final target = _target;
    if (target == null) return 0;
    return target.sourceLendableQty < target.shortageQty
        ? target.sourceLendableQty
        : target.shortageQty;
  }

  /// 调入模式的本计划待补数：优先物理缺口，无缺口时用建议补供量
  /// （在途调入入口即按该口径放开）。
  double get _remainingNeed {
    if (!widget.receiveIntoCurrent) {
      return _sourceMaterial.allocatedAvailableQty;
    }
    return _sourceMaterial.shortageQty > 0
        ? _sourceMaterial.shortageQty
        : _sourceMaterial.additionalSupplyRecommendedQty;
  }

  bool get _hasMorePages => widget.futureTransfer
      ? _futurePage < _futureTotalPages
      : widget.receiveIntoCurrent
      ? _spotPage < _spotTotalPages
      : _page < _totalPages;

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
    final keyword = _searchController.text;
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
      // 每种入口只查自己的一路候选：让出查接受方、现货调入查供料方、
      // 在途调入查专属份额。加载后自动匹配最合适的来源并预填数量。
      final spotPage = widget.receiveIntoCurrent && !widget.futureTransfer
          ? await widget.repository.materialCrossReallocationSources(
              targetAnalysisId: _sourceAnalysis.analysisId,
              targetMaterialLineId: _sourceMaterial.materialLineId,
              page: reset ? 1 : _spotPage + 1,
              keyword: keyword,
            )
          : null;
      final futurePage = widget.futureTransfer
          ? await widget.repository.materialFutureTransferSources(
              targetAnalysisId: _sourceAnalysis.analysisId,
              targetMaterialId: _sourceMaterial.materialLineId,
              page: reset ? 1 : _futurePage + 1,
              keyword: keyword,
            )
          : null;
      final candidatePage = !widget.receiveIntoCurrent
          ? await widget.repository.materialCrossReallocationCandidates(
              sourceAnalysisId: _sourceAnalysis.analysisId,
              sourceMaterialLineId: _sourceMaterial.materialLineId,
              page: reset ? 1 : _page + 1,
              keyword: keyword,
            )
          : null;
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        if (reset) _candidates.clear();
        final incoming = <MaterialReallocationEndpointCandidate>[
          if (spotPage != null) ...spotPage.items,
          if (futurePage != null) ...futurePage.items,
          if (candidatePage != null) ...candidatePage.items,
        ];
        for (final candidate in incoming) {
          final index = _candidates.indexWhere(
            (existing) => _sameCandidate(existing, candidate),
          );
          if (index >= 0) {
            _candidates[index] = candidate;
          } else {
            _candidates.add(candidate);
          }
        }
        if (spotPage != null) {
          _spotPage = spotPage.page;
          _spotTotalPages = spotPage.totalPages;
        }
        if (futurePage != null) {
          _futurePage = futurePage.page;
          _futureTotalPages = futurePage.totalPages;
        }
        if (candidatePage != null) {
          _page = candidatePage.page;
          _totalPages = candidatePage.totalPages;
        }
        _rebuildIdentityIndex();
        _loading = false;
        _loadingMore = false;
        _loadError = null;
        if (selected != null) {
          final matches = _candidates.where(
            (candidate) => _sameCandidate(candidate, selected),
          );
          _target = matches.isEmpty ? null : matches.first;
          if (_target == null) {
            _submitError = '原$_counterpartRole已不再符合调拨条件，请重新选择；数量和原因已保留。';
          }
        } else if (_target == null && !_multiSelect) {
          _autoSelectBest();
        }
        if (_multiSelect) {
          _pruneMissingSelections();
          if (selected == null && _selectedIds.isEmpty && reset) {
            _autoSelectCovering();
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

  void _rebuildIdentityIndex() {
    _byIdentity
      ..clear()
      ..addEntries(
        _candidates.map(
          (candidate) => MapEntry(_candidateIdentity(candidate), candidate),
        ),
      );
  }

  /// 多选模式下清理已消失的勾选；数量输入保留到弹窗销毁，避免动画切换
  /// 期间释放仍被旧行引用的控制器。
  void _pruneMissingSelections() {
    final vanished = _selectedIds
        .where((identity) => !_byIdentity.containsKey(identity))
        .toList();
    _selectedIds.removeAll(vanished);
    if (vanished.isNotEmpty && _submitError == null) {
      _submitError = '部分原$_counterpartRole已不再符合条件，已自动取消勾选；请核对后提交。';
    }
  }

  double _coverageOf(MaterialReallocationEndpointCandidate candidate) =>
      candidate.sourceLendableQty < candidate.shortageQty
      ? candidate.sourceLendableQty
      : candidate.shortageQty;

  /// 自动判断最合适的来源（单选模式）：现货优先于在途、可覆盖缺口
  /// 更多者优先、交期更早者优先、在途避免晚到或交期不明。
  void _autoSelectBest() {
    MaterialReallocationEndpointCandidate? best;
    for (final candidate in _candidates) {
      if (!_candidateHasCas(candidate)) continue;
      if (best == null || _preferredOver(candidate, best)) best = candidate;
    }
    if (best == null) return;
    _target = best;
    _qtyController.text = widget.qtyText(_maxQty);
  }

  /// 自动判断（在途多选）：按优先级依次勾选来源直到覆盖本计划待补数。
  void _autoSelectCovering() {
    final ordered = [..._candidates.where(_candidateHasCas)]
      ..sort((left, right) => _preferredOver(left, right) ? -1 : 1);
    var remaining = _remainingNeed;
    for (final candidate in ordered) {
      if (remaining <= 0) break;
      final take = _coverageOf(candidate) < remaining
          ? _coverageOf(candidate)
          : remaining;
      if (take <= 0) continue;
      final identity = _candidateIdentity(candidate);
      _selectedIds.add(identity);
      _selectedQtyControllers.putIfAbsent(
        identity,
        () => TextEditingController(text: widget.qtyText(take)),
      );
      remaining -= take;
    }
  }

  bool _preferredOver(
    MaterialReallocationEndpointCandidate candidate,
    MaterialReallocationEndpointCandidate incumbent,
  ) {
    final candidateFuture = candidate is MaterialFutureTransferSource;
    final incumbentFuture = incumbent is MaterialFutureTransferSource;
    if (candidateFuture != incumbentFuture) return incumbentFuture;
    if (candidateFuture && incumbentFuture) {
      final candidateLate = candidate.lateOrUnknown;
      final incumbentLate = incumbent.lateOrUnknown;
      if (candidateLate != incumbentLate) return incumbentLate;
    }
    final coverage = _coverageOf(candidate);
    final incumbentCoverage = _coverageOf(incumbent);
    if (coverage != incumbentCoverage) return coverage > incumbentCoverage;
    final date = candidate.deliveryDate?.trim() ?? '';
    final incumbentDate = incumbent.deliveryDate?.trim() ?? '';
    if (date.isEmpty != incumbentDate.isEmpty) return incumbentDate.isEmpty;
    if (date.isNotEmpty && date != incumbentDate) {
      return date.compareTo(incumbentDate) < 0;
    }
    return false;
  }

  void _onSearchChanged(String _) {
    unawaited(_loadCandidates(reset: true));
  }

  void _selectCandidate(String? identity) {
    if (_locked) return;
    final selected = identity == null ? null : _byIdentity[identity];
    if (selected == null || !_candidateHasCas(selected)) return;
    setState(() {
      _target = selected;
      _dirty = true;
      _submitError = null;
      _qtyController.text = widget.qtyText(_maxQty);
    });
  }

  void _toggleCandidate(String? identity) {
    if (_locked || identity == null) return;
    final candidate = _byIdentity[identity];
    if (candidate == null || !_candidateHasCas(candidate)) return;
    setState(() {
      if (_selectedIds.contains(identity)) {
        _selectedIds.remove(identity);
      } else {
        _selectedIds.add(identity);
        _selectedQtyControllers.putIfAbsent(
          identity,
          () => TextEditingController(
            text: widget.qtyText(_defaultMultiQty(candidate, identity)),
          ),
        );
      }
      _dirty = true;
      _submitError = null;
    });
  }

  /// 手动勾选时的默认数量：本计划待补数扣除其它已勾选来源后，该来源
  /// 还能贡献多少。
  double _defaultMultiQty(
    MaterialReallocationEndpointCandidate candidate,
    String identity,
  ) {
    var taken = 0.0;
    for (final other in _selectedIds) {
      if (other == identity) continue;
      taken +=
          double.tryParse(_selectedQtyControllers[other]?.text.trim() ?? '') ??
          0;
    }
    final remaining = (_remainingNeed - taken)
        .clamp(0.0, _remainingNeed)
        .toDouble();
    final coverage = _coverageOf(candidate);
    return coverage < remaining ? coverage : remaining;
  }

  String _candidateIdentity(MaterialReallocationEndpointCandidate candidate) =>
      candidate is MaterialFutureTransferSource
      ? candidate.sourceAllocationId
      : '${candidate.analysisId}|${candidate.materialLineId}';

  String? _validateQty(String? raw) {
    final qty = double.tryParse(raw?.trim() ?? '');
    if (qty == null || !qty.isFinite || qty <= 0) return '请输入大于 0 的调拨数量';
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw?.trim() ?? '')) {
      return '数量最多支持 4 位小数';
    }
    if (qty > _maxQty) {
      return '最多可调 ${widget.qtyText(_maxQty)}（不超过服务端权威可调量和本计划缺口）';
    }
    return null;
  }

  String? _validateMultiQty(
    MaterialFutureTransferSource candidate,
    String? raw,
  ) {
    final qty = double.tryParse(raw?.trim() ?? '');
    if (qty == null || !qty.isFinite || qty <= 0) return '请输入大于 0 的数量';
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(raw?.trim() ?? '')) {
      return '数量最多支持 4 位小数';
    }
    final max = candidate.availableQty < candidate.targetUncoveredQty
        ? candidate.availableQty
        : candidate.targetUncoveredQty;
    if (qty > max) {
      return '最多可调 ${widget.qtyText(max)}（不超过该来源可调量和本计划缺口）';
    }
    return null;
  }

  /// 业务原因 2026-09-13 起选填：仅保留长度上限。
  String? _validateReason(String? raw) {
    final reason = raw?.trim() ?? '';
    if (reason.length > 1000) return '业务原因不能超过 1000 个字';
    return null;
  }

  double get _selectedTotal => _selectedIds.fold(0, (sum, identity) {
    return sum +
        (double.tryParse(
              _selectedQtyControllers[identity]?.text.trim() ?? '',
            ) ??
            0);
  });

  Future<void> _submit() async {
    if (_multiSelect) {
      await _submitBatch();
      return;
    }
    final target = _target;
    if (target == null || _submitting) return;
    setState(() {
      _showValidation = true;
      _submitError = null;
    });
    if (_formKey.currentState?.validate() != true) return;
    final qty = double.parse(_qtyController.text.trim());
    final reason = _reasonController.text.trim();
    final isFuture = target is MaterialFutureTransferSource;
    final key = businessIdempotencyKey(
      isFuture
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
        if (isFuture) target.sourceAllocationId,
        qty,
        reason,
      ].join('|'),
    );
    setState(() => _submitting = true);
    try {
      final view = isFuture
          ? await widget.repository.createMaterialFutureTransfer(
              targetAnalysis: _sourceAnalysis,
              targetMaterialId: _sourceMaterial.materialLineId,
              source: target,
              qty: qty,
              allowLateSupply: true,
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
          futureTransfer: isFuture,
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
              : productionErrorMessage(error, fallback: '跨计划调拨失败，请重试');
        });
      }
    }
  }

  /// 在途多选：逐笔提交，每笔独立幂等键；成功一笔就用服务端返回的接收方
  /// 快照重基版本，再提交下一笔。失败时保留剩余勾选，同键重试不重复调入。
  Future<void> _submitBatch() async {
    if (_submitting) return;
    setState(() {
      _showValidation = true;
      _submitError = null;
    });
    if (_formKey.currentState?.validate() != true) return;
    final entries = <(String, MaterialFutureTransferSource, double)>[];
    for (final identity in _selectedIds.toList()) {
      final candidate = _byIdentity[identity];
      if (candidate is! MaterialFutureTransferSource) continue;
      final qty = double.tryParse(
        _selectedQtyControllers[identity]?.text.trim() ?? '',
      );
      if (qty == null || qty <= 0) continue;
      entries.add((identity, candidate, qty));
    }
    if (entries.isEmpty) return;
    final total = _selectedTotal;
    if (total > _remainingNeed + 0.00005) {
      setState(() {
        _submitError =
            '合计调入 ${widget.qtyText(total)} 超过本计划待补 ${widget.qtyText(_remainingNeed)}，请调小数量';
      });
      return;
    }
    final reason = _reasonController.text.trim();
    setState(() {
      _submitting = true;
      _batchDone = 0;
      _batchTotal = entries.length;
    });
    ProductionMaterialAnalysisView? lastView;
    try {
      for (final (identity, candidate, qty) in entries) {
        final key = businessIdempotencyKey(
          'material-analysis-private-future-transfer',
          [
            _sourceAnalysis.analysisId,
            _sourceAnalysis.version,
            _sourceAnalysis.fingerprint,
            _sourceMaterial.materialLineId,
            candidate.analysisId,
            candidate.version,
            candidate.fingerprint,
            candidate.materialLineId,
            candidate.sourceAllocationId,
            qty,
            reason,
          ].join('|'),
        );
        final view = await widget.repository.createMaterialFutureTransfer(
          targetAnalysis: _sourceAnalysis,
          targetMaterialId: _sourceMaterial.materialLineId,
          source: candidate,
          qty: qty,
          allowLateSupply: true,
          reason: reason,
          idempotencyKey: key,
        );
        if (!mounted) return;
        widget.onCompleted?.call(
          MaterialReallocationCompletion(
            sourceAnalysisId: candidate.analysisId,
            sourceMaterialLineId: candidate.materialLineId,
            targetAnalysisId: _sourceAnalysis.analysisId,
            targetMaterialLineId: _sourceMaterial.materialLineId,
            quantity: qty,
            sourceLabel: candidate.displayAnalysisLabel,
            idempotencyKey: key,
            futureTransfer: true,
          ),
        );
        lastView = view;
        _rebaseFromView(view);
        setState(() {
          _batchDone++;
          _selectedIds.remove(identity);
        });
      }
      _finish(lastView);
    } catch (error) {
      if (!mounted) return;
      if (error is ApiException && error.code == 'CONFLICT') {
        await _recoverConflictBatch(error, entries.length);
      } else {
        // 与单笔同样的未知回执口径：冻结数量/来源/原因，重试沿用原幂等键。
        setState(() {
          _submitting = false;
          _uncertain =
              error is! ApiException ||
              error is NetworkException ||
              error is NetworkTimeoutException ||
              error.code == 'INTERNAL' ||
              (error.httpStatus ?? 0) >= 500;
          if (_uncertain) {
            _submitError =
                '已提交 $_batchDone/${entries.length} 笔；剩余结果未知，'
                '已冻结数量和来源，请同键重试确认，不会重复调入。';
          } else {
            _submitError =
                '已提交 $_batchDone/${entries.length} 笔；余下未提交。'
                '（${productionErrorMessage(error, fallback: '请重试')}）';
          }
        });
      }
    }
  }

  void _rebaseFromView(ProductionMaterialAnalysisView view) {
    _sourceAnalysis = view;
    for (final material in view.materials) {
      if (material.materialLineId == _sourceMaterial.materialLineId) {
        _sourceMaterial = material;
        break;
      }
    }
    widget.onSourceRebased?.call(view);
  }

  Future<void> _recoverConflictBatch(ApiException conflict, int planned) async {
    try {
      final latest = await widget.repository.materialAnalysisDetail(
        _sourceAnalysis.analysisId,
      );
      if (!mounted) return;
      _rebaseFromView(latest);
      await _loadCandidates(reset: true, preserveSelection: true);
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError =
            '库存或计划状态已变化，已提交 $_batchDone/$planned 笔；剩余来源已按最新候选刷新，数量保留，请核对后再次确认。';
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
        title: widget.receiveIntoCurrent ? '放弃未提交的调入内容？' : '放弃未提交的让料内容？',
        content: const Text('已选择的来源、数量和业务原因不会保存。'),
        confirmLabel: '放弃并返回',
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
    final hasSelection = _multiSelect
        ? _selectedIds.isNotEmpty
        : _target != null;
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
              Expanded(child: _candidatePanel(theme)),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                transitionBuilder: (child, animation) => SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 1),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
                child: hasSelection
                    ? _selectionPanel(theme)
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme) => Padding(
    padding: const EdgeInsets.fromLTRB(
      UtenSpacing.s12,
      UtenSpacing.s12,
      UtenSpacing.s8,
      UtenSpacing.s12,
    ),
    child: Row(
      children: [
        IconButton(
          tooltip: '返回',
          onPressed: _locked ? null : _requestClose,
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.futureTransfer
                    ? '调入其他计划在途'
                    : widget.receiveIntoCurrent
                    ? '从其他计划调入'
                    : '跨计划让料',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                widget.futureTransfer
                    ? '已自动匹配可调入的专属在途；可多选，到货并检验合格后生效。'
                    : widget.receiveIntoCurrent
                    ? '已自动匹配可调入的现货来源；确认后立即生效。'
                    : '让出后本计划优先待补；接受计划无需返还。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _sourceSummary(ThemeData theme) {
    final receiving = widget.receiveIntoCurrent;
    final label = receiving
        ? (_sourceMaterial.shortageQty > 0 ? '本计划缺口 ' : '尚需补供 ')
        : '现货覆盖 ';
    final qty = receiving
        ? (_sourceMaterial.shortageQty > 0
              ? _sourceMaterial.shortageQty
              : _sourceMaterial.additionalSupplyRecommendedQty)
        : _sourceMaterial.allocatedAvailableQty;
    final numberColor = receiving
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    final needQty = Text.rich(
      TextSpan(
        style: theme.textTheme.titleSmall,
        children: [
          TextSpan(text: label),
          TextSpan(
            text: widget.qtyText(qty),
            style: TextStyle(
              color: numberColor,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          if (_sourceMaterial.unitName?.trim().isNotEmpty == true)
            TextSpan(text: ' ${_sourceMaterial.unitName!.trim()}'),
        ],
      ),
    );
    return Semantics(
      container: true,
      label:
          '$_currentRole：${widget.sourceProductLabel}，'
          '${_sourceMaterial.goodsName ?? _sourceMaterial.goodsCode ?? '物料'}，'
          '$label${widget.qtyText(qty)}',
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        color: theme.colorScheme.surfaceContainerLow,
        child: Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$_currentRole：${widget.sourceProductLabel}',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              '物料：${_sourceMaterial.goodsName ?? _sourceMaterial.goodsCode ?? '未命名物料'}',
            ),
            needQty,
          ],
        ),
      ),
    );
  }

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
            ? '暂无可调入的其他计划专属在途。\n'
                  '只有已批准、未实收且仍有份额的来源可调；公共余量请从「从公共在途中调入」采用。'
            : widget.receiveIntoCurrent
            ? '暂无可调入的其他计划现货。\n'
                  '同主仓、同货品/颜色/单位且未被正式预留的现货才会出现；已有未补齐的调入关系时须先完成或撤销。'
            : '没有符合条件的其它计划。\n'
                  '候选须同主仓范围、同货品/颜色/单位，且仍有真实缺口。',
      );
    }
    return ListView.separated(
      key: const Key('cross-reallocation-candidates-list'),
      controller: _candidateScrollController,
      itemCount: _candidates.length + (_hasMorePages ? 1 : 0),
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
        return _candidateTile(theme, _candidates[index]);
      },
    );
  }

  Widget _candidateTile(
    ThemeData theme,
    MaterialReallocationEndpointCandidate candidate,
  ) {
    final identity = _candidateIdentity(candidate);
    final enabled = _candidateHasCas(candidate) && !_locked;
    final isFuture = candidate is MaterialFutureTransferSource;
    if (!_candidateHasCas(candidate)) {
      return ListTile(
        key: ValueKey('candidate-stale-$identity'),
        dense: true,
        title: const Text('候选快照已失效，请重新加载'),
      );
    }
    final secondaryDetails = <String>[
      if (candidate.productLabel?.trim().isNotEmpty == true)
        candidate.productLabel!.trim(),
      if (isFuture && candidate.documentNo?.trim().isNotEmpty == true)
        candidate.documentNo!.trim(),
      if (candidate.deliveryDate?.trim().isNotEmpty == true)
        '${isFuture ? '预计到货' : '交期'} ${candidate.deliveryDate}',
    ];
    // 主行与选择框同排垂直居中：来源名大字在左，可调数量加粗着色居右，
    // 货品名/单号/交期合并为一行小字副行。
    final title = Row(
      children: [
        Expanded(
          child: Text(
            candidate.displayAnalysisLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Text(
          '${isFuture ? '可调' : '可让'} ${widget.qtyText(candidate.sourceLendableQty)}',
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
        ),
        if (widget.onOpenSourcePlan != null)
          IconButton(
            key: ValueKey('candidate-jump-plan-$identity'),
            tooltip: '查看来源计划',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            onPressed: () => widget.onOpenSourcePlan!(candidate),
            icon: const Icon(Icons.open_in_new_rounded),
          ),
        if (widget.onOpenSourceDocument != null &&
            isFuture &&
            candidate.documentId?.trim().isNotEmpty == true)
          IconButton(
            key: ValueKey('candidate-jump-doc-$identity'),
            tooltip: '查看来源采购/委外单',
            visualDensity: VisualDensity.compact,
            iconSize: 20,
            onPressed: () => widget.onOpenSourceDocument!(candidate),
            icon: const Icon(Icons.receipt_long_outlined),
          ),
      ],
    );
    final subtitle = secondaryDetails.isEmpty
        ? null
        : Text(
            secondaryDetails.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
    if (_multiSelect) {
      return CheckboxListTile(
        key: ValueKey('future-transfer-candidate-$identity'),
        value: _selectedIds.contains(identity),
        onChanged: enabled ? (_) => _toggleCandidate(identity) : null,
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: UtenSpacing.s4,
        ),
        title: title,
        subtitle: subtitle,
      );
    }
    return RadioGroup<String>(
      groupValue: _target == null ? null : _candidateIdentity(_target!),
      onChanged: (value) {
        if (!_locked) _selectCandidate(value);
      },
      child: RadioListTile<String>(
        key: ValueKey(
          isFuture
              ? 'future-transfer-candidate-${candidate.sourceAllocationId}'
              : 'cross-reallocation-candidate-${candidate.analysisId}-${candidate.materialLineId}',
        ),
        value: identity,
        enabled: enabled,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: UtenSpacing.s4,
        ),
        title: title,
        subtitle: subtitle,
      ),
    );
  }

  /// 底部滑入填写条：列表占满主体，点选来源后从底部滑出数量/原因/确认，
  /// 避免左右两栏互相挤压（2026-09-13 布局改版）。
  /// 底部滑入填写条：列表占满主体，点选来源后从底部滑出数量/原因/确认，
  /// 避免左右两栏互相挤压（2026-09-13 布局改版）。
  Widget _selectionPanel(ThemeData theme) {
    final rows =
        <
          ({
            Key key,
            String label,
            String sub,
            TextEditingController controller,
            String? Function(String?) validator,
          })
        >[];
    if (_multiSelect) {
      for (final identity in _selectedIds.toList()) {
        final candidate = _byIdentity[identity];
        if (candidate is! MaterialFutureTransferSource) continue;
        rows.add((
          key: Key('future-transfer-qty-$identity'),
          label: candidate.displayAnalysisLabel,
          sub: [
            if (candidate.documentNo?.trim().isNotEmpty == true)
              candidate.documentNo!.trim(),
            '可调 ${widget.qtyText(candidate.availableQty)}',
          ].join(' · '),
          controller:
              _selectedQtyControllers[identity] ?? TextEditingController(),
          validator: (raw) => _validateMultiQty(candidate, raw),
        ));
      }
    } else {
      final target = _target!;
      rows.add((
        key: const Key('cross-reallocation-qty'),
        label: target.displayAnalysisLabel,
        sub: [
          if (target.productLabel?.trim().isNotEmpty == true)
            target.productLabel!.trim(),
          '可${widget.receiveIntoCurrent ? '调入' : '让出'} ${widget.qtyText(target.sourceLendableQty)}',
        ].join(' · '),
        controller: _qtyController,
        validator: _validateQty,
      ));
    }
    // 只选一个来源（含在途多选模式下仅勾一个）时：数量与业务原因严格同行；
    // 多个来源时逐来源数量成行，业务原因与数量列对齐成右栏。
    final single = rows.length == 1;
    Widget qtyField(
      TextEditingController controller,
      Key key,
      String? Function(String?) validator,
    ) => SizedBox(
      width: 220,
      child: TextFormField(
        errorBuilder: utenTextFieldErrorBuilder,
        key: key,
        controller: controller,
        ignorePointers: false,
        enabled: !_locked,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        validator: validator,
        onChanged: (_) => setState(() {
          _dirty = true;
          _submitError = null;
        }),
        decoration: UtenInputDecoration(
          InputDecoration(
            label: fieldLabel(
              widget.receiveIntoCurrent ? '调入数量' : '让料数量',
              theme,
            ),
            suffixText: _sourceMaterial.unitName,
          ),
        ),
      ),
    );
    final scrollContent = <Widget>[
      if (_multiSelect)
        Text(
          '已选 ${rows.length} 个来源 · 合计 ${widget.qtyText(_selectedTotal)}'
          ' · 待补 ${widget.qtyText(_remainingNeed)}',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      if (_submitting && _multiSelect)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s4),
          child: Text(
            '正在提交 第 ${_batchDone + 1}/$_batchTotal 笔…',
            key: const Key('future-transfer-batch-progress'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      if (single)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                rows.first.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                rows.first.sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      // 数量与业务原因同行：左数量、右原因（单选一行；多选逐来源数量、原因整行）。
      if (single)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              qtyField(
                rows.first.controller,
                rows.first.key,
                rows.first.validator,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(child: _reasonField(theme)),
            ],
          ),
        )
      else ...[
        for (final row in rows)
          Padding(
            padding: const EdgeInsets.only(
              top: UtenSpacing.s8,
              bottom: UtenSpacing.s4,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        row.sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s12),
                qtyField(row.controller, row.key, row.validator),
              ],
            ),
          ),
        // 多来源时业务原因与数量输入列对齐（右栏），保持两栏网格视觉一致。
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Row(
            children: [
              const Spacer(),
              SizedBox(width: 220, child: _reasonField(theme)),
            ],
          ),
        ),
      ],
      const SizedBox(height: UtenSpacing.s4),
      _impactLine(theme),
      if (_submitError != null)
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
    ];
    return Material(
      key: const Key('cross-reallocation-selection-panel'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Form(
        key: _formKey,
        autovalidateMode: _showValidation
            ? AutovalidateMode.onUserInteraction
            : AutovalidateMode.disabled,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  children: scrollContent,
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  children: [
                    UtenButton(
                      key: const Key('cross-reallocation-cancel'),
                      size: UtenButtonSize.large,
                      type: UtenButtonType.ghost,
                      onPressed: _locked ? null : _requestClose,
                      child: const Text('返回'),
                    ),
                    const Spacer(),
                    UtenButton(
                      key: const Key('cross-reallocation-confirm'),
                      size: UtenButtonSize.large,
                      isLoading: _submitting,
                      onPressed: _submitting ? null : _submit,
                      child: Text(
                        _uncertain
                            ? '重试确认调拨'
                            : _multiSelect
                            ? '确认调入（${rows.length} 笔）'
                            : widget.receiveIntoCurrent
                            ? '确认调入'
                            : '确认让料',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 确认影响的单行摘要（替代旧的两栏大卡片）。
  Widget _impactLine(ThemeData theme) {
    final qty = _multiSelect
        ? _selectedTotal
        : double.tryParse(_qtyController.text.trim()) ?? 0;
    if (qty <= 0) return const SizedBox.shrink();
    final qtyText = widget.qtyText(qty);
    final (
      text,
      semantics,
    ) = _multiSelect || _target is MaterialFutureTransferSource
        ? (
            '共调入 $qtyText 在途份额；到货并检验合格后缺口才减少，未实收前可撤销。',
            '共调入 $qtyText 未来供给，尚未实收、不计现货',
          )
        : widget.receiveIntoCurrent
        ? (
            '供料计划让出 $qtyText 并优先待补；本计划缺口立即减少 $qtyText，无需返还。',
            '供料计划让出 $qtyText 并优先待补，本计划缺口立即减少 $qtyText，无需返还',
          )
        : (
            '本计划让出 $qtyText 并优先待补；接受计划无需返还。',
            '当前计划让出 $qtyText 并优先待补，接受计划缺口减少 $qtyText，无需返还',
          );
    return Semantics(
      key: const Key('cross-reallocation-impact'),
      container: true,
      label: semantics,
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _reasonField(ThemeData theme) => TextFormField(
    errorBuilder: utenTextFieldErrorBuilder,
    key: const Key('cross-reallocation-reason'),
    controller: _reasonController,
    ignorePointers: false,
    enabled: !_locked,
    minLines: 1,
    maxLines: 3,
    maxLength: 1000,
    validator: _validateReason,
    onChanged: (_) => setState(() {
      _dirty = true;
      _submitError = null;
    }),
    decoration: UtenInputDecoration(
      InputDecoration(
        label: fieldLabel('业务原因(选填)', theme),
        alignLabelWithHint: true,
        // maxLength 默认计数器会占一行把框顶高，统一压掉（限制仍生效）。
        counterText: '',
      ),
    ),
  );

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
}
