// 组装信息导入：使用「导出组件」的列，序号级联段
// （1 / 2 / 2.1）表达层级——导出改完可直接导回。
// ADR-129：「设计使用数量」列必填(旧表头「数量」也认，为空报错不再按 1)；
// 「真实使用数量」列只读，导入时忽略(由生产学习累计，不能靠导入改)。
//
// 交互仿货品导入（选文件 → 检测报告 → 提交），但更轻：
// - 检测返回绑定文件和BOM状态的版本，提交锁定后复核；发生变化保留文件并重新检测；
// - 默认合并核对，保留文件外组件；冲突在整页表格中选择，空值可补齐。
// - 完整替换(另需 goods:bom:delete)和追加保留为显式选择的既有操作。
// - 检测报告列出逐行错误（第几行/哪列/为什么）与提醒（名称不一致等，不拦提交）。
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_drop_target.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../repositories/goods_bom_import_repository.dart';
import 'goods_import_file_reader.dart';
import 'goods_import_review.dart';
import 'basic_data_l10n.dart';
import 'import_file_queue.dart';

/// 弹出组装信息导入。[onImported] 在提交成功后回调（宿主刷新 BOM 树）。
Future<void> showGoodsBomImport(
  BuildContext context,
  WidgetRef ref, {
  required String goodsId,
  required VoidCallback onImported,
  bool Function()? canWrite,
  bool Function()? canReplace,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoodsBomImportDialog(
      goodsId: goodsId,
      onImported: onImported,
      canWrite: canWrite,
      canReplace: canReplace,
    ),
  );
}

class _GoodsBomImportDialog extends ConsumerStatefulWidget {
  const _GoodsBomImportDialog({
    required this.goodsId,
    required this.onImported,
    this.canWrite,
    this.canReplace,
  });

  final String goodsId;
  final VoidCallback onImported;
  final bool Function()? canWrite;
  final bool Function()? canReplace;

  @override
  ConsumerState<_GoodsBomImportDialog> createState() =>
      _GoodsBomImportDialogState();
}

class _GoodsBomImportDialogState extends ConsumerState<_GoodsBomImportDialog> {
  bool _detecting = false;
  bool _committing = false;
  BomImportReport? _report;
  BomImportResult? _result;
  Uint8List? _bytes;
  String? _detectionMessage;
  bool _commitUncertain = false;
  bool _reviewing = false;
  Set<String>? _submittedSelection;
  final _queue = ImportFileQueue();

  BomImportMode _mode = BomImportMode.merge;

  void _beginDetection() {
    setState(() {
      _mode = BomImportMode.merge;
      _detecting = true;
      _bytes = null;
      _report = null;
      _result = null;
      _detectionMessage = null;
      _commitUncertain = false;
      _submittedSelection = null;
      _queue.phase = ImportFileQueuePhase.detecting;
    });
  }

  Future<void> _pickAndDetect() async {
    if (_detecting || _committing || _reviewing) return;
    final uncertain = _commitUncertain;
    final previousReport = _report;
    final previousBytes = _bytes;
    final previousSelection = _submittedSelection;
    final previousMode = _mode;
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
              _mode = previousMode;
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
          _mode = previousMode;
        }
      });
      context.appError('选择文件时出了问题，请重试'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _replaceQueueAndDetect(List<PlatformFile> files) async {
    if (!mounted || files.isEmpty || _committing || _reviewing) return;
    setState(() => _queue.replacePending(files));
    await _detectCurrentFile();
  }

  /// Start only after the previous file has committed, using current BOM state.
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
          .read(goodsBomImportRepositoryProvider)
          .detect(widget.goodsId, bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
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
      } else if (!report.hasErrors && _queue.approved) {
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
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _detecting = false;
        _detectionMessage = e.message;
        _queue.pause(failed: true);
      });
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _detecting = false;
        _queue.pause(failed: true);
      });
      context.appError('读取或检测文件时出了问题，请重试'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _reviewAndCommit() async {
    final report = _report;
    if (_reviewing ||
        _detecting ||
        _committing ||
        report == null ||
        report.hasErrors) {
      return;
    }
    if (_commitUncertain) {
      await _commit(_submittedSelection ?? {});
      return;
    }
    Set<String> selected = {};
    if (_mode == BomImportMode.merge && report.reviewRows.isNotEmpty) {
      setState(() {
        _reviewing = true;
        _queue.phase = ImportFileQueuePhase.reviewing;
      });
      final result = await reviewGoodsImport(
        context,
        title: basicDataL10n(context).bomImportReviewTitle,
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
    if (widget.canWrite?.call() == false ||
        (_mode == BomImportMode.replace &&
            widget.canReplace?.call() == false)) {
      return;
    }
    final bytes = _bytes;
    final fingerprint = _report?.stateFingerprint;
    if (_detecting ||
        _committing ||
        bytes == null ||
        _report == null ||
        _report!.hasErrors ||
        fingerprint == null) {
      return;
    }
    setState(() {
      _committing = true;
      _submittedSelection = Set.of(selected);
      _queue.phase = ImportFileQueuePhase.committing;
    });
    var succeeded = false;
    try {
      final result = await ref
          .read(goodsBomImportRepositoryProvider)
          .commit(
            widget.goodsId,
            bytes,
            mode: _mode,
            stateFingerprint: fingerprint,
            replaceRowKeys: selected,
          );
      if (!mounted) return;
      setState(() {
        _result = result;
        _queue.approved = true;
        _queue.succeed(
          basicDataL10n(context).importResultSummary(
            result.added,
            result.filledCount,
            result.updatedCount,
            result.ignoredCount,
            result.unchangedCount,
          ),
        );
      });
      succeeded = true;
      widget.onImported();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _queue.pause(failed: true));
      if (e.code != 'NETWORK' &&
          e.code != 'NETWORK_TIMEOUT' &&
          (e.httpStatus ?? 0) < 500) {
        setState(() {
          _report = null;
          _detectionMessage = e.message;
          _commitUncertain = false;
        });
      } else if (e.code == 'NETWORK' ||
          e.code == 'NETWORK_TIMEOUT' ||
          (e.httpStatus ?? 0) >= 500) {
        _markUncertain();
      }
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _queue.pause(failed: true));
      _markUncertain();
      context.appError('不确定导入是否成功，请先核对组装清单(BOM)；重试会沿用上次检测，避免重复写入');
    } finally {
      if (mounted) setState(() => _committing = false);
    }
    if (mounted && succeeded && _queue.hasPending) await _detectCurrentFile();
  }

  void _markUncertain() {
    setState(() => _commitUncertain = true);
    widget.onImported();
  }

  Future<void> _redetectCurrentFile() async {
    if (_detecting || _committing || _reviewing) return;
    _queue.approved = false;
    await _detectCurrentFile();
  }

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
        child: UtenAlertDialog(
          showCloseButton: true,
          onClose: (_committing || _detecting || _reviewing)
              ? null
              : () => Navigator.pop(context),
          closeEnabled: !_committing && !_detecting && !_reviewing,
          scrollable: false,
          title: Row(
            children: [
              const Flexible(child: Text('导入组件')),
              UtenFieldHintIcon(
                info:
                    '${basicDataL10n(context).importFilesTransactionNote}\n\n'
                    '选择未加密的 .xlsx 文件（「导出组件」的格式），系统会先检测再导入。\n\n'
                    '使用「导出组件」的列；序号列的级联段表达层级(1 = 顶层组件，'
                    '2.1 = 序号 2 组件的下级)，导出改完可直接导回。'
                    '必填列：序号、物料编号、设计使用数量(旧表头「数量」也认)；'
                    '真实使用数量列只读，导入时忽略。',
                dense: true,
              ),
            ],
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(child: _body(theme)),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            if (_result == null && _report == null && _bytes == null)
              FilledButton(
                onPressed: _committing || _detecting || _reviewing
                    ? null
                    : _pickAndDetect,
                child: const Text('选择文件并检测'),
              ),
            if (_result == null && (_report != null || _bytes != null))
              TextButton(
                onPressed: _committing || _detecting || _reviewing
                    ? null
                    : _pickAndDetect,
                child: const Text('重新选择文件'),
              ),
            if (_result == null &&
                _report != null &&
                !_report!.hasErrors &&
                _report!.stateFingerprint != null)
              FilledButton(
                onPressed: (_committing || _detecting || _reviewing)
                    ? null
                    : _reviewAndCommit,
                child: Text(
                  _committing
                      ? '正在导入…'
                      : _commitUncertain
                      ? basicDataL10n(context).importRetryPrevious
                      : _mode == BomImportMode.merge &&
                            _report!.reviewRows.isNotEmpty
                      ? basicDataL10n(context).importReviewOpen
                      : '导入',
                ),
              ),
          ],
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
    if (_detecting || _committing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_result != null) {
      final r = _result!;
      final done = Text(
        '导入完成：已把 ${r.added} 个组件导入 ${r.targets} 个货品'
        '${r.removed > 0 ? '（替换掉 ${r.removed} 个旧组件）' : ''}，'
        '文件共 ${r.levels} 层。\n'
        '${basicDataL10n(context).importResultSummary(r.added, r.filledCount, r.updatedCount, r.ignoredCount, r.unchangedCount)}',
        style: theme.textTheme.bodyMedium,
      );
      if (r.warnings.isEmpty) return done;
      // 写入后的提醒 (如整批领料的料单个重量与货品资料单重相差 20% 以上)：不拦写入，请核对。
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          done,
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '请核对 ${r.warnings.length} 条提醒：',
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          for (final w in r.warnings.take(50))
            Text('· $w', style: theme.textTheme.bodySmall),
        ],
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: UtenSpacing.s12),
        if (_queue.hasPending)
          TextButton(
            onPressed: _detectCurrentFile,
            child: Text(basicDataL10n(context).importFilesContinue),
          ),
      ],
    );
  }

  void _chooseMode(BomImportMode? value) {
    if (!_commitUncertain &&
        (value != BomImportMode.replace ||
            widget.canReplace?.call() != false)) {
      setState(() => _mode = value ?? BomImportMode.replace);
    }
  }

  Widget _reportView(ThemeData theme, BomImportReport r) {
    final levelSummary = r.levelCounts.isEmpty
        ? ''
        : '；共 ${r.levelCounts.length} 层（${r.levelCounts.join(' / ')}）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_commitUncertain)
          const Text('上次提交结果还不确定，请先核对组装清单(BOM)；重试会沿用上次检测，避免重复写入。'),
        if (!r.hasErrors && r.stateFingerprint == null)
          const Text('服务器没有返回检测结果，请升级服务端后重新检测。'),
        Text(
          r.hasErrors
              ? '共 ${r.totalRows} 行，发现 ${r.errors.length} 个问题，请修正后重传'
              : '共 ${r.totalRows} 行，可导入$levelSummary', // TODO(l10n): 补 arb
          style: theme.textTheme.bodyMedium,
        ),
        if (r.hasErrors) ...[
          const SizedBox(height: UtenSpacing.s12),
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in r.errors.take(200))
                  Text(
                    '• 第 ${e.rowNum} 行 · ${e.column}：${e.message}',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
        ],
        if (r.warnings.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          for (final w in r.warnings.take(50))
            Text(
              '· 第 ${w.rowNum} 行 · ${w.column}：${w.message}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
        if (!r.hasErrors) ...[
          if (_mode == BomImportMode.merge) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              basicDataL10n(context).importReviewSummary(
                r.addedRows,
                r.fillRows,
                r.conflictRows,
                r.unchangedRows,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Text('导入方式：', style: theme.textTheme.titleSmall), // TODO(l10n): 补 arb
          RadioGroup<BomImportMode>(
            groupValue: _mode,
            onChanged: _chooseMode,
            child: Column(
              children: [
                UtenDialogSettingTile(
                  canRequestFocus: false,
                  icon: Icons.merge_type_rounded,
                  title: Text(basicDataL10n(context).bomImportMergeLabel),
                  selected: _mode == BomImportMode.merge,
                  onTap: _commitUncertain
                      ? null
                      : () => _chooseMode(BomImportMode.merge),
                  trailing: Radio<BomImportMode>(
                    value: BomImportMode.merge,
                    enabled: !_commitUncertain,
                  ),
                ),
                if (widget.canReplace?.call() != false) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  UtenDialogSettingTile(
                    canRequestFocus: false,
                    icon: Icons.find_replace_rounded,
                    title: const Text('按文件为准（替换各级现有组件）'),
                    selected: _mode == BomImportMode.replace,
                    onTap: _commitUncertain
                        ? null
                        : () => _chooseMode(BomImportMode.replace),
                    trailing: Radio<BomImportMode>(
                      value: BomImportMode.replace,
                      enabled: !_commitUncertain,
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                UtenDialogSettingTile(
                  canRequestFocus: false,
                  icon: Icons.playlist_add_rounded,
                  title: const Text('在现有组件后追加'),
                  selected: _mode == BomImportMode.append,
                  onTap: _commitUncertain
                      ? null
                      : () => _chooseMode(BomImportMode.append),
                  trailing: Radio<BomImportMode>(
                    value: BomImportMode.append,
                    enabled: !_commitUncertain,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
