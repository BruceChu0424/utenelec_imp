// 货品批量导入流程弹窗：选文件 → 检测 → 报告（错误/将自动新建）→ 确认导入 → 结果。
//
// 先检测再核对：新货品新增，已有货品补齐空值；非空冲突在全页中选择替换或忽略。
// 文件内重复、必填缺失和身份歧义阻止提交；服务端按检测计划在事务中复核并写入。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_drop_target.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../core/network/api_exception.dart';
import '../models/goods_import.dart';
import '../repositories/goods_import_repository.dart';
import 'basic_data_l10n.dart';
import 'goods_import_file_reader.dart';
import 'goods_import_review.dart';
import 'import_file_queue.dart';

/// 弹出导入流程。[onImported] 在导入成功后回调（调用方刷新货品列表）。
Future<void> showGoodsImportDialog(
  BuildContext context,
  WidgetRef ref, {
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
          child: _GoodsImportDialog(onImported: onImported),
        ),
      ),
    ),
  );
}

class _GoodsImportDialog extends ConsumerStatefulWidget {
  const _GoodsImportDialog({this.onImported});
  final VoidCallback? onImported;

  @override
  ConsumerState<_GoodsImportDialog> createState() => _GoodsImportDialogState();
}

class _GoodsImportDialogState extends ConsumerState<_GoodsImportDialog> {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 弹窗整块都是拖放接收区（Web/桌面端）：xlsx 直接拖进来检测。
    return PopScope(
      canPop: !_detecting && !_committing && !_reviewing,
      child: UtenDropTarget(
        enabled: !_detecting && !_committing && !_reviewing,
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
                      child: Text(
                        '导入货品',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
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
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: _actions(theme),
              ),
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
        ImportFileQueueSummary(queue: _queue),
        _currentBody(theme),
      ],
    );
  }

  Widget _currentBody(ThemeData theme) {
    if (_committing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_result != null) {
      return _resultView(theme, _result!);
    }
    if (_detecting) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_report != null) {
      return _reportView(theme, _report!);
    }
    if (_bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _detectionMessage ?? basicDataL10n(context).importRedetectRequired,
          ),
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
        Text('选择未加密的 .xlsx 文件，系统会先检测再导入。', style: theme.textTheme.bodyMedium),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '${basicDataL10n(context).goodsImportTemplateHint}\n'
          '可导入列：客户货品名称、客户型号、系列、型号、规格、材质、主颜色、单位、来源、价格、'
          '最小起订量、订货倍数、状态、后模镶件编号、备注。\n'
          '${basicDataL10n(context).goodsNameEnImportHint}\n'
          '模具编号、模具名称、所属仓库、生产车间仅识别不导入。\n'
          '${basicDataL10n(context).goodsImportMergeHint}\n'
          '缺失的分类/颜色/单位会自动新建。\n'
          '如从「导出货品」取得文件，导出时请不要设置密码。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
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

  Widget _reportView(ThemeData theme, GoodsImportReport r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '共 ${r.totalRows} 行，有效数据 ${r.dataRows} 行'
          '${r.hasErrors ? "，发现 ${r.errors.length} 个问题" : "，可导入 ${r.readyToImport} 条"}',
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (!r.hasErrors && r.reviewRows.isNotEmpty) ...[
          Text(
            basicDataL10n(context).importReviewSummary(
              r.addedRows,
              r.fillRows,
              r.conflictRows,
              r.unchangedRows,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(basicDataL10n(context).importReviewIgnoreExplanation),
        ],
        if (r.hasErrors) ...[
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('需修正后重传：', style: theme.textTheme.titleSmall),
                const SizedBox(height: UtenSpacing.s4),
                for (final e in r.errors.take(200))
                  Text(
                    '• 第 ${e.rowNum} 行 · ${e.column}：${e.message}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ] else ...[
          _willCreate(theme, '将自动新建分类', r.willCreateCategories),
          _willCreate(theme, '将自动新建颜色', r.willCreateColors),
          _willCreate(theme, '将自动新建单位', r.willCreateUnits),
          if (r.restorableRows > 0) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '其中 ${r.restorableRows} 条编号与已删除货品相同，导入时将按清单内容恢复这些货品。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.tertiary,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '检测通过，可确认导入 ${r.readyToImport} 条。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ],
      ],
    );
  }

  Widget _willCreate(ThemeData theme, String title, List<String> items) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$title(${items.length})：${items.take(20).join("、")}${items.length > 20 ? " …" : ""}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
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
        Text(
          basicDataL10n(context).importResultSummary(
            r.createdCount,
            r.filledCount,
            r.updatedCount,
            r.ignoredCount,
            r.unchangedCount,
          ),
        ),
        if (r.createdCategories > 0 ||
            r.createdColors > 0 ||
            r.createdUnits > 0)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              '新建分类 ${r.createdCategories} / 颜色 ${r.createdColors} / 单位 ${r.createdUnits}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: UtenSpacing.s8),
        if (r.batchId.isNotEmpty &&
            r.importedCount > 0 &&
            _queue.completed.length <= 1)
          Text(
            '如导入有误，可点工具栏「撤回」一键撤销本次导入。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    if (_committing) {
      return const SizedBox.shrink();
    }
    if (_result != null) {
      return UtenButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('完成'),
      );
    }
    // 初始 / 检测后
    final canConfirm =
        _report != null &&
        !_report!.hasErrors &&
        _report!.planId?.isNotEmpty == true &&
        _bytes != null;
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      children: [
        UtenButton(
          type: UtenButtonType.secondary,
          icon: Icons.file_upload_outlined,
          isLoading: _detecting,
          onPressed: _pickAndDetect,
          child: Text(_report == null ? '选择 Excel 文件' : '重新选择'),
        ),
        if (_queue.hasPending && _report == null && _bytes == null)
          UtenButton(
            onPressed: _detecting || _reviewing ? null : _detectCurrentFile,
            child: Text(basicDataL10n(context).importFilesContinue),
          ),
        if (canConfirm)
          UtenButton(
            icon: Icons.check_rounded,
            onPressed: _reviewing || _detecting
                ? null
                : _commitUncertain
                ? () => _commit(_submittedSelection ?? {})
                : _reviewAndCommit,
            child: Text(
              _commitUncertain
                  ? basicDataL10n(context).importRetryPrevious
                  : _report!.reviewRows.isNotEmpty
                  ? basicDataL10n(context).importReviewOpen
                  : '确认导入',
            ),
          ),
      ],
    );
  }

  Future<void> _pickAndDetect() async {
    if (_detecting || _committing || _reviewing) return;
    final uncertain = _commitUncertain;
    final previousReport = _report;
    final previousBytes = _bytes;
    final previousSelection = _submittedSelection;
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
            if (uncertain) {
              _report = previousReport;
              _bytes = previousBytes;
              _submittedSelection = previousSelection;
              _commitUncertain = true;
            }
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
        if (uncertain) {
          _report = previousReport;
          _bytes = previousBytes;
          _submittedSelection = previousSelection;
          _commitUncertain = true;
        }
      });
      context.appError('选择文件时出了问题，请重试');
    }
  }

  Future<void> _replaceQueueAndDetect(List<PlatformFile> files) async {
    if (!mounted || files.isEmpty || _committing || _reviewing) return;
    setState(() => _queue.replacePending(files));
    await _detectCurrentFile();
  }

  /// Never detect later files before the current file has committed.
  Future<void> _detectCurrentFile() async {
    final file = _queue.current;
    if (!mounted || file == null || _committing || _reviewing) return;
    _beginDetection();
    try {
      final bytes = _queue.currentBytes ?? await readGoodsImportFile(file);
      if (!mounted) return;
      _queue.currentBytes = bytes;
      _bytes = bytes;
      final report = await ref
          .read(goodsImportRepositoryProvider)
          .detect(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _pickedName = file.name;
        _report = report;
        _result = null;
        _detecting = false;
        if (report.hasErrors) {
          _queue.pause(failed: true);
        } else {
          _queue.phase = ImportFileQueuePhase.waiting;
        }
      });
      if (!report.hasErrors && report.reviewRows.isNotEmpty) {
        await _reviewAndCommit();
      } else if (!report.hasErrors &&
          report.restorableRows == 0 &&
          _queue.approved) {
        await _commit({});
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
      setState(() {
        _detecting = false;
        _queue.pause(failed: true);
      });
      context.appApiError(
        e,
        fallback: '读取或检测文件时出了问题，请刷新页面重试；仍失败请联系管理员重启 Web 服务',
      );
    }
  }

  void _beginDetection() {
    setState(() {
      _detecting = true;
      _report = null;
      _bytes = null;
      _result = null;
      _submittedSelection = null;
      _commitUncertain = false;
      _detectionMessage = null;
      _queue.phase = ImportFileQueuePhase.detecting;
    });
  }

  Future<void> _redetectCurrentFile() async {
    if (_detecting || _committing || _reviewing) return;
    _queue.approved = false;
    await _detectCurrentFile();
  }

  Future<void> _reviewAndCommit() async {
    final report = _report;
    if (_detecting ||
        _committing ||
        _reviewing ||
        report == null ||
        report.hasErrors) {
      return;
    }
    Set<String> selected = {};
    if (report.reviewRows.isNotEmpty) {
      setState(() {
        _reviewing = true;
        _queue.phase = ImportFileQueuePhase.reviewing;
      });
      final result = await reviewGoodsImport(
        context,
        title: basicDataL10n(context).goodsImportReviewTitle,
        filename: _queue.current == null
            ? null
            : basicDataL10n(context).importFilesCurrent(
                _queue.position,
                _queue.total,
                _queue.current!.name,
              ),
        rows: report.reviewRows,
        added: report.addedRows,
        filled: report.fillRows,
        conflicts: report.conflictRows,
        unchanged: report.unchangedRows,
      );
      if (!mounted) return;
      setState(() => _reviewing = false);
      if (result == null) {
        setState(() => _queue.pause());
        return;
      }
      selected = result;
    }
    await _commit(selected);
  }

  Future<void> _commit(Set<String> selected) async {
    if (_committing || _detecting || _report?.hasErrors != false) return;
    final bytes = _bytes;
    final planId = _report?.planId;
    if (bytes == null || planId == null || planId.isEmpty) {
      context.appError('检测结果已过期，请重新选择文件并检测');
      return;
    }
    setState(() {
      _committing = true;
      _submittedSelection = Set.of(selected);
      _queue.phase = ImportFileQueuePhase.committing;
    });
    try {
      final res = await ref
          .read(goodsImportRepositoryProvider)
          .commit(
            bytes,
            planId: planId,
            filename: _pickedName,
            replaceRowKeys: selected,
          );
      if (!mounted) return;
      setState(() {
        _result = res;
        _committing = false;
        _queue.approved = true;
        _queue.succeed(
          basicDataL10n(context).importResultSummary(
            res.createdCount,
            res.filledCount,
            res.updatedCount,
            res.ignoredCount,
            res.unchangedCount,
          ),
        );
      });
      context.appSuccess('已导入 ${res.importedCount} 条货品');
      widget.onImported?.call();
      if (_queue.hasPending) await _detectCurrentFile();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _committing = false;
        _queue.pause(failed: true);
        if (e is ApiException &&
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
      });
      if (_commitUncertain) widget.onImported?.call();
      context.appApiError(e);
    }
  }
}
