// 货品批量导入流程弹窗：选文件 → 检测 → 报告（错误/将自动新建）→ 确认导入 → 结果。
//
// 先检测再核对：新货品新增，已有货品补齐空值；非空冲突在全页中选择替换或忽略。
// 文件内重复、必填缺失和身份歧义阻止提交；服务端按检测计划在事务中复核并写入。
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_drop_target.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/account_action_owner.dart';
import '../models/goods_import.dart';
import '../pages/goods_import_preview_page.dart';
import '../repositories/goods_import_repository.dart';
import 'basic_data_l10n.dart';
import 'goods_import_file_reader.dart';
import 'import_file_queue.dart';
import 'goods_import_reference_picker.dart';

/// 弹出导入流程。[onImported] 在导入成功后回调（调用方刷新货品列表）。
/// [mode] 为导入模式（2026-10-28 起入口先三选一；缺省混合=现有行为）。
Future<void> showGoodsImportDialog(
  BuildContext context,
  WidgetRef ref, {
  GoodsImportMode mode = GoodsImportMode.mixed,
  VoidCallback? onImported,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    // 导入弹窗文字（步骤说明/错误结果）可框选复制（准则 §3.4）。
    builder: (ctx) => SelectionArea(
      child: UtenDialogFrame(
        shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 580,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
          ),
          child: _GoodsImportDialog(mode: mode, onImported: onImported),
        ),
      ),
    ),
  );
}

class _GoodsImportDialog extends ConsumerStatefulWidget {
  const _GoodsImportDialog({
    this.mode = GoodsImportMode.mixed,
    this.onImported,
  });
  final GoodsImportMode mode;
  final VoidCallback? onImported;

  @override
  ConsumerState<_GoodsImportDialog> createState() => _GoodsImportDialogState();
}

class _GoodsImportDialogState extends ConsumerState<_GoodsImportDialog> {
  late final AccountActionOwner _owner;
  Route<GoodsImportPreviewDecision>? _previewRoute;
  Route<dynamic>? _dialogRoute;
  bool _detecting = false;
  bool _committing = false;
  String? _pickedName;
  Uint8List? _bytes;
  GoodsImportReport? _report;
  GoodsImportResult? _result;
  bool _reviewing = false;
  Set<String>? _submittedSelection;
  bool _commitUncertain = false;
  String? _detectionMessage;
  final _queue = ImportFileQueue();
  GoodsImportCorrections _cellCorrections = {};
  GoodsImportCorrections _problemDraft = {};
  final _excludedRowNums = <int>{};
  GoodsImportCorrections? _submittedCorrections;
  Set<int>? _submittedExclusions;
  final _fileResults = <GoodsImportResult>[];
  final _allResults = <GoodsImportResult>[];
  bool _correctionsNeedDetection = false;
  Set<int>? _reviewExclusions;
  bool _previewHasRemaining = false;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      onInvalidated: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          final navigator = Navigator.of(context);
          final preview = _previewRoute;
          if (preview?.isActive == true) navigator.removeRoute(preview!);
          final dialog = _dialogRoute;
          if (dialog?.isActive == true) navigator.removeRoute(dialog!);
        });
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _dialogRoute = ModalRoute.of(context);
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 弹窗整块都是拖放接收区（Web/桌面端）：xlsx 直接拖进来检测。
    return PopScope(
      canPop: !_detecting && !_committing && !_reviewing,
      child: UtenDropTarget(
        enabled:
            !_detecting && !_committing && !_reviewing && !_commitUncertain,
        hint: '松开鼠标检测 Excel',
        onFiles: _replaceQueueAndDetect,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s16,
                  UtenSpacing.s12,
                  UtenSpacing.s8,
                  UtenSpacing.s12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              '导入货品',
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          UtenFieldHintIcon(
                            info:
                                '${basicDataL10n(context).importFilesTransactionNote}\n\n'
                                '选择 .xlsx 文件，核对全部货品后再导入。\n\n'
                                '${basicDataL10n(context).goodsImportTemplateHint}\n'
                                '可导入列：客户货品名称、客户型号、系列、型号、规格、材质、主颜色、单位、来源、价格、'
                                '最小起订量、订货倍数、状态、后模镶件编号、备注。\n'
                                '${basicDataL10n(context).goodsNameEnImportHint}\n'
                                '模具编号、模具名称、所属仓库、生产车间仅识别不导入。\n'
                                '${basicDataL10n(context).goodsImportMergeHint}\n'
                                '缺失的分类/颜色/单位会自动新建。\n'
                                '如从「导出货品」取得文件，导出时请不要设置密码。',
                            dense: true,
                          ),
                          const SizedBox(width: UtenSpacing.s8),
                          // 标题旁标注本次导入模式（入口三选一带进来的口径）。
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UtenSpacing.s8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.secondaryContainer,
                              borderRadius: BorderRadius.circular(
                                UtenRadius.sm,
                              ),
                            ),
                            child: Text(
                              widget.mode.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSecondaryContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: _detecting || _committing || _reviewing
                          ? null
                          : () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: _body(theme),
                ),
              ),
              if (!_detecting && !_committing) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: _actions(theme),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_result == null)
          ImportFileQueueSummary(queue: _queue, compact: true),
        _currentBody(theme),
      ],
    );
  }

  Widget _currentBody(ThemeData theme) {
    if (_committing) {
      return _progress('正在导入货品');
    }
    if (_result != null) {
      return _resultView(theme, _sumResults(_result!, _allResults));
    }
    if (_detecting) {
      return _progress('正在检查文件');
    }
    if (_report != null) {
      return _reportView(theme, _report!);
    }
    if (_bytes != null || _detectionMessage != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _detectionMessage ?? basicDataL10n(context).importRedetectRequired,
          ),
          if (_bytes != null)
            TextButton(
              onPressed: _redetectCurrentFile,
              child: Text(basicDataL10n(context).importRedetectCurrent),
            ),
        ],
      );
    }
    // 初始：选文件 + 格式说明
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_pickedName != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '已选：$_pickedName',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _progress(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s32),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: UtenSpacing.s16),
          Text(label),
        ],
      ),
    ),
  );

  Widget _reportView(ThemeData theme, GoodsImportReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('共 ${r.dataRows} 条货品，可导入 ${r.readyToImport} 条'),
        const SizedBox(height: UtenSpacing.s12),
        if (_detectionMessage != null)
          Text(
            _detectionMessage!,
            style: TextStyle(color: theme.colorScheme.error),
          ),
        if (r.hasErrors) ...[
          Text(
            '${r.errors.length} 处待修正',
            style: TextStyle(color: theme.colorScheme.error),
          ),
          if (r.previewRows.isEmpty)
            for (final error in r.errors)
              Text(
                '${error.column}：${error.message}',
                style: TextStyle(color: theme.colorScheme.error),
              ),
        ] else ...[
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s8,
            children: [
              _willCreate(theme, '新增分类', r.willCreateCategories),
              _willCreate(theme, '新增颜色', r.willCreateColors),
              _willCreate(theme, '新增单位', r.willCreateUnits),
            ],
          ),
          if (r.restorableRows > 0) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '将恢复 ${r.restorableRows} 条已删除货品',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _willCreate(ThemeData theme, String title, List<String> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Tooltip(
        message: items.join('\n'),
        child: Text(
          '$title ${items.length}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _resultView(ThemeData theme, GoodsImportResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s8),
            Text('导入完成', style: theme.textTheme.titleMedium),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text('已导入 ${r.importedCount} 条货品', style: theme.textTheme.bodyMedium),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s8,
          children: [
            if (r.createdCount > 0) Text('新增 ${r.createdCount}'),
            if (r.filledCount > 0) Text('补齐 ${r.filledCount}'),
            if (r.updatedCount > 0) Text('替换 ${r.updatedCount}'),
            if (r.ignoredCount > 0) Text('保留 ${r.ignoredCount}'),
            if (r.unchangedCount > 0) Text('相同 ${r.unchangedCount}'),
          ],
        ),
        if (r.createdCategories > 0 ||
            r.createdColors > 0 ||
            r.createdUnits > 0)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              [
                if (r.createdCategories > 0) '新建分类 ${r.createdCategories}',
                if (r.createdColors > 0) '新建颜色 ${r.createdColors}',
                if (r.createdUnits > 0) '新建单位 ${r.createdUnits}',
              ].join('，'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (_queue.completed.length > 1) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '已完成 ${_queue.completed.length} 个文件',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    if (_committing || _detecting) {
      return const SizedBox.shrink();
    }
    if (_result != null) {
      return UtenButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('完成'),
      );
    }
    // 初始 / 检测后
    final canReview = _report?.previewRows.isNotEmpty == true && _bytes != null;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.file_upload_outlined,
          isLoading: _detecting,
          onPressed: _commitUncertain ? null : _pickAndDetect,
          child: Text(_report == null ? '选择 Excel 文件' : '重新选择'),
        ),
        if (_queue.hasPending && _report == null && _bytes == null)
          UtenButton(
            onPressed: _detecting || _reviewing || _commitUncertain
                ? null
                : _detectCurrentFile,
            child: Text(basicDataL10n(context).importFilesContinue),
          ),
        if (canReview || _commitUncertain)
          UtenButton(
            icon: Icons.check_rounded,
            onPressed: _reviewing || _detecting
                ? null
                : _commitUncertain
                ? () => _commit(_submittedSelection ?? {})
                : _openPreview,
            child: Text(
              _commitUncertain
                  ? basicDataL10n(context).importRetryPrevious
                  : '查看导入预览',
            ),
          ),
      ],
    );
  }

  Future<void> _pickAndDetect() async {
    if (_detecting || _committing || _reviewing || _commitUncertain) return;
    final previousReport = _report;
    final previousBytes = _bytes;
    final previousMessage = _detectionMessage;
    _beginDetection();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        allowMultiple: true,
        withReadStream: true,
        readSequential: true,
      );
      final files = result?.files;
      if (files == null || files.isEmpty) {
        if (mounted) {
          setState(() {
            _detecting = false;
            _queue.pause();
            _report = previousReport;
            _bytes = previousBytes;
            _detectionMessage = previousMessage;
          });
        }
        return;
      }
      await _replaceQueueAndDetect(files);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detecting = false;
        _queue.pause(failed: true);
        _report = previousReport;
        _bytes = previousBytes;
        _detectionMessage = previousMessage;
      });
      context.appError('选择文件时出了问题，请重试');
    }
  }

  Future<void> _replaceQueueAndDetect(List<PlatformFile> files) async {
    if (!mounted ||
        files.isEmpty ||
        _committing ||
        _reviewing ||
        _commitUncertain) {
      return;
    }
    setState(() {
      _queue.replacePending(files);
      _resetCurrentFileProgress();
    });
    await _detectCurrentFile();
  }

  /// Never detect later files before the current file has committed.
  Future<void> _detectCurrentFile() async {
    final file = _queue.current;
    if (!mounted ||
        file == null ||
        _committing ||
        _reviewing ||
        _commitUncertain) {
      return;
    }
    final previousProblems = _correctionsNeedDetection ? _report : null;
    _beginDetection();
    try {
      final bytes = _queue.currentBytes ?? await readGoodsImportFile(file);
      if (!mounted) return;
      _queue.currentBytes = bytes;
      _bytes = bytes;
      final report = await ref
          .read(goodsImportRepositoryProvider)
          .detect(
            bytes,
            cellCorrections: freezeGoodsImportCorrections(_cellCorrections),
            excludedRowNums: Set.unmodifiable(_excludedRowNums),
            mode: widget.mode,
          );
      if (!mounted || !_owner.isCurrent) return;
      setState(() {
        _bytes = bytes;
        _pickedName = file.name;
        _report = report;
        _correctionsNeedDetection = false;
        _result = null;
        _detecting = false;
        if (report.hasErrors) {
          _queue.pause(failed: true);
        } else {
          _queue.phase = ImportFileQueuePhase.waiting;
        }
      });
      if (report.previewRows.isNotEmpty) {
        await _openPreview();
      } else if (!report.hasErrors) {
        setState(() => _detectionMessage = '未取得完整货品预览，请重新检查文件');
      }
    } on GoodsImportFileException catch (e) {
      if (!mounted) return;
      setState(() {
        _detecting = false;
        _detectionMessage = e.message;
        _queue.pause(failed: true);
      });
      context.appError(e.message);
    } catch (e) {
      if (!mounted) return;
      final message =
          humanErrorMessage(e) ??
          basicDataL10n(context).goodsImportDetectionFailed;
      setState(() {
        _detecting = false;
        _detectionMessage = message;
        if (previousProblems != null) _report = previousProblems;
        _queue.pause(failed: true);
      });
      context.appApiError(e, fallback: message);
      if (previousProblems != null && previousProblems.previewRows.isNotEmpty) {
        await _openPreview();
      }
    }
  }

  void _beginDetection() {
    setState(() {
      _detecting = true;
      _report = null;
      _bytes = null;
      _result = null;
      _submittedSelection = null;
      _submittedCorrections = null;
      _submittedExclusions = null;
      _commitUncertain = false;
      _detectionMessage = null;
      _queue.phase = ImportFileQueuePhase.detecting;
    });
  }

  Future<void> _redetectCurrentFile() async {
    if (_detecting || _committing || _reviewing || _commitUncertain) return;
    _queue.approved = false;
    await _detectCurrentFile();
  }

  Future<void> _commit(Set<String> selected) async {
    if (!_owner.isCurrent ||
        _committing ||
        _detecting ||
        _report == null ||
        _correctionsNeedDetection) {
      return;
    }
    final bytes = _bytes;
    final planId = _report?.planId;
    if (bytes == null || planId == null || planId.isEmpty) {
      context.appError('检测结果已过期，请重新选择文件并检测');
      return;
    }
    final report = _report!;
    final wasUncertain = _commitUncertain;
    final replacements = Set<String>.unmodifiable(
      wasUncertain && _submittedSelection != null
          ? _submittedSelection!
          : selected,
    );
    final corrections = wasUncertain && _submittedCorrections != null
        ? _submittedCorrections!
        : freezeGoodsImportCorrections(_cellCorrections);
    final exclusions = wasUncertain && _submittedExclusions != null
        ? _submittedExclusions!
        : _reviewExclusions ?? Set<int>.unmodifiable(_excludedRowNums);
    setState(() {
      _committing = true;
      _submittedSelection = replacements;
      _submittedCorrections = corrections;
      _submittedExclusions = exclusions;
      _queue.phase = ImportFileQueuePhase.committing;
    });
    try {
      final res = await ref
          .read(goodsImportRepositoryProvider)
          .commit(
            bytes,
            planId: planId,
            filename: _pickedName,
            replaceRowKeys: replacements,
            cellCorrections: corrections,
            excludedRowNums: exclusions,
            mode: widget.mode,
          );
      if (!mounted || !_owner.isCurrent) return;
      setState(() {
        _fileResults.add(res);
        _allResults.add(res);
        _excludedRowNums.addAll(report.readyRowNums);
        _cellCorrections.removeWhere(
          (row, _) => _excludedRowNums.contains(row),
        );
        _problemDraft = {
          for (final entry in _problemDraft.entries)
            if (!_excludedRowNums.contains(entry.key)) entry.key: entry.value,
        };
        _committing = false;
        _commitUncertain = false;
        final summary = basicDataL10n(context).importResultSummary(
          res.createdCount,
          res.filledCount,
          res.updatedCount,
          res.ignoredCount,
          res.unchangedCount,
        );
        if (report.hasErrors || _previewHasRemaining) {
          _result = null;
          _queue.recordPartial(summary);
          _queue.pause();
        } else {
          _result = _combinedResult(res);
          _queue.approved = true;
          _queue.succeed(_summaryOf(_result!));
        }
      });
      context.appSuccess('已导入 ${res.importedCount} 条货品');
      widget.onImported?.call();
      if (report.hasErrors || _previewHasRemaining) {
        _reviewExclusions = null;
        _previewHasRemaining = false;
        await _detectCurrentFile();
      } else if (_queue.hasPending) {
        _resetCurrentFileProgress();
        await _detectCurrentFile();
      }
    } catch (e) {
      if (!mounted || !_owner.isCurrent) return;
      setState(() {
        _committing = false;
        _queue.pause(failed: true);
        // A consumed-plan 4xx describes this retry only. It cannot prove that
        // an earlier request whose response was lost rolled back.
        if (wasUncertain) {
          _commitUncertain = true;
        } else if (e is ApiException &&
            e.code != 'NETWORK' &&
            e.code != 'NETWORK_TIMEOUT' &&
            (e.httpStatus ?? 0) < 500) {
          _report = null;
          _commitUncertain = false;
          _detectionMessage = e.message;
        } else {
          _commitUncertain =
              e is! ApiException ||
              e.code == 'NETWORK' ||
              e.code == 'NETWORK_TIMEOUT' ||
              (e.httpStatus ?? 0) >= 500;
        }
        if (_commitUncertain) {
          _detectionMessage = '提交结果待核对，请查看修改历史确认结果。';
        }
      });
      if (_commitUncertain) widget.onImported?.call();
      context.appApiError(e);
    }
  }

  void _resetCurrentFileProgress() {
    _reviewExclusions = null;
    _previewHasRemaining = false;
    _cellCorrections = {};
    _problemDraft = {};
    _excludedRowNums.clear();
    _submittedCorrections = null;
    _submittedExclusions = null;
    _fileResults.clear();
    _correctionsNeedDetection = false;
  }

  String _summaryOf(GoodsImportResult result) =>
      basicDataL10n(context).importResultSummary(
        result.createdCount,
        result.filledCount,
        result.updatedCount,
        result.ignoredCount,
        result.unchangedCount,
      );

  GoodsImportResult _combinedResult(GoodsImportResult latest) =>
      _sumResults(latest, _fileResults);

  GoodsImportResult _sumResults(
    GoodsImportResult latest,
    List<GoodsImportResult> results,
  ) => GoodsImportResult(
    batchId: latest.batchId,
    importedCount: results.fold(0, (n, r) => n + r.importedCount),
    createdCategories: results.fold(0, (n, r) => n + r.createdCategories),
    createdColors: results.fold(0, (n, r) => n + r.createdColors),
    createdUnits: results.fold(0, (n, r) => n + r.createdUnits),
    createdCategoryPaths: [for (final r in results) ...r.createdCategoryPaths],
    createdCount: results.fold(0, (n, r) => n + r.createdCount),
    filledCount: results.fold(0, (n, r) => n + r.filledCount),
    updatedCount: results.fold(0, (n, r) => n + r.updatedCount),
    ignoredCount: results.fold(0, (n, r) => n + r.ignoredCount),
    unchangedCount: results.fold(0, (n, r) => n + r.unchangedCount),
    restoredCount: results.fold(0, (n, r) => n + r.restoredCount),
  );

  Future<void> _openPreview() async {
    final report = _report;
    final bytes = _bytes;
    if (!_owner.isCurrent ||
        report == null ||
        bytes == null ||
        _reviewing ||
        _committing ||
        _detecting ||
        _commitUncertain) {
      return;
    }
    setState(() {
      _reviewing = true;
      _queue.phase = ImportFileQueuePhase.reviewing;
    });
    final route = MaterialPageRoute<GoodsImportPreviewDecision>(
      builder: (_) => GoodsImportPreviewPage(
        report: report,
        filename: _queue.current?.name ?? _pickedName ?? '',
        mode: widget.mode,
        cellCorrections: _problemDraft.isNotEmpty
            ? _problemDraft
            : _cellCorrections,
        excludedRowNums: Set.of(_excludedRowNums),
        needsValidation: _correctionsNeedDetection,
        pickReference:
            (
              pickerContext, {
              required field,
              required currentValue,
              required currentCategorySegments,
              required draftValues,
            }) => pickGoodsImportReference(
              pickerContext,
              ref,
              field: field,
              currentValue: currentValue,
              currentCategorySegments: currentCategorySegments,
              draftValues: draftValues,
              isCurrent: () => mounted && _owner.isCurrent,
            ),
        detect: (corrections, exclusions) async {
          if (!_owner.isCurrent) throw StateError('操作身份已改变');
          final next = await ref
              .read(goodsImportRepositoryProvider)
              .detect(
                bytes,
                cellCorrections: corrections,
                excludedRowNums: exclusions,
                mode: widget.mode,
              );
          if (!_owner.isCurrent) throw StateError('操作身份已改变');
          return next;
        },
        onDraftChanged: (corrections, removed) {
          _problemDraft = corrections;
          _cellCorrections = {
            for (final entry in corrections.entries)
              entry.key: Map.of(entry.value),
          };
          _excludedRowNums
            ..clear()
            ..addAll(removed);
          _correctionsNeedDetection = true;
        },
      ),
    );
    _previewRoute = route;
    final decision = await Navigator.of(context).push(route);
    _previewRoute = null;
    if (!mounted || !_owner.isCurrent) return;
    setState(() {
      _reviewing = false;
      if (decision == null) _queue.pause();
    });
    if (decision == null) return;
    setState(() {
      _report = decision.report;
      _cellCorrections = {
        for (final entry in decision.cellCorrections.entries)
          entry.key: Map.of(entry.value),
      };
      _problemDraft = decision.cellCorrections;
      _excludedRowNums
        ..clear()
        ..addAll(decision.removedRowNums);
      _reviewExclusions = decision.excludedRowNums;
      _previewHasRemaining = decision.hasRemaining;
      _correctionsNeedDetection = false;
    });
    await _commit(decision.replaceRowKeys);
  }
}
