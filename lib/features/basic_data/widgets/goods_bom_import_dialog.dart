// 组装信息导入弹窗（2026-09-25）：格式 = 「导出组件」的 13 列，序号级联段
// （1 / 2 / 2.1）表达层级——导出改完可直接导回。
//
// 交互仿货品导入（选文件 → 检测报告 → 提交），但更轻：
// - 不需要 planId：提交时服务端重新解析全量复检；
// - 提交方式二选一：按文件为准（替换各级现有组件，与「粘贴-替换」同语义，需
//   goods:bom:delete）/ 在现有组件后追加（与「粘贴-同级追加」同语义）；
// - 检测报告列出逐行错误（第几行/哪列/为什么）与提醒（名称不一致等，不拦提交）。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../repositories/goods_bom_import_repository.dart';
import 'goods_import_file_reader.dart';

/// 弹出组装信息导入。[onImported] 在提交成功后回调（宿主刷新 BOM 树）。
Future<void> showGoodsBomImport(
  BuildContext context,
  WidgetRef ref, {
  required String goodsId,
  required VoidCallback onImported,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _GoodsBomImportDialog(
      goodsId: goodsId,
      onImported: onImported,
    ),
  );
}

class _GoodsBomImportDialog extends ConsumerStatefulWidget {
  const _GoodsBomImportDialog({
    required this.goodsId,
    required this.onImported,
  });

  final String goodsId;
  final VoidCallback onImported;

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

  BomImportMode _mode = BomImportMode.replace;

  Future<void> _pickAndDetect() async {
    setState(() => _detecting = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx'],
        withReadStream: true,
        readSequential: true,
      );
      final f = result?.files.firstOrNull;
      if (f == null) {
        if (mounted) setState(() => _detecting = false);
        return;
      }
      final bytes = await readGoodsImportFile(f);
      final report = await ref
          .read(goodsBomImportRepositoryProvider)
          .detect(widget.goodsId, bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _report = report;
        _result = null;
        _detecting = false;
      });
    } on GoodsImportFileException catch (e) {
      if (!mounted) return;
      setState(() => _detecting = false);
      context.appError(e.message);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _detecting = false);
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _detecting = false);
      context.appError('Excel 文件选择或检测异常，请重试'); // TODO(l10n): 补 arb
    }
  }

  Future<void> _commit() async {
    final bytes = _bytes;
    if (bytes == null) return;
    setState(() => _committing = true);
    try {
      final result = await ref
          .read(goodsBomImportRepositoryProvider)
          .commit(widget.goodsId, bytes, mode: _mode);
      if (!mounted) return;
      setState(() => _result = result);
      widget.onImported();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('导入失败，请稍后重试'); // TODO(l10n): 补 arb
    } finally {
      if (mounted) setState(() => _committing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('导入组件'), // TODO(l10n): 补 arb
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(child: _body(theme)),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        TextButton(
          onPressed: (_committing || _detecting)
              ? null
              : () => Navigator.pop(context),
          child: const Text('关闭'), // TODO(l10n): 补 arb
        ),
        if (_result == null && _report != null && !_report!.hasErrors)
          FilledButton(
            onPressed: _committing ? null : _commit,
            child: Text(_committing ? '正在导入…' : '导入'), // TODO(l10n): 补 arb
          ),
      ],
    );
  }

  Widget _body(ThemeData theme) {
    if (_detecting || _committing) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_result != null) {
      final r = _result!;
      return Text(
        '导入完成：共 ${r.added} 个组件写入 ${r.targets} 个货品'
        '${r.removed > 0 ? '（替换掉 ${r.removed} 个旧组件）' : ''}，'
        '文件共 ${r.levels} 层。', // TODO(l10n): 补 arb
        style: theme.textTheme.bodyMedium,
      );
    }
    if (_report != null) {
      return _reportView(theme, _report!);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '选择未加密的 .xlsx 文件（「导出组件」的格式），系统会先检测再导入。',
          style: theme.textTheme.bodyMedium, // TODO(l10n): 补 arb
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '格式 = 导出组件的 13 列；序号列的级联段表达层级（1 = 顶层组件，'
          '2.1 = 序号 2 组件的下级），导出改完可直接导回。'
          '必填列：序号、物料编号、数量。', // TODO(l10n): 补 arb
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        FilledButton(
          onPressed: _pickAndDetect,
          child: const Text('选择文件并检测'), // TODO(l10n): 补 arb
        ),
      ],
    );
  }

  Widget _reportView(ThemeData theme, BomImportReport r) {
    final levelSummary = r.levelCounts.isEmpty
        ? ''
        : '；共 ${r.levelCounts.length} 层（${r.levelCounts.join(' / ')}）';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
          const SizedBox(height: UtenSpacing.s12),
          Text('导入方式：', style: theme.textTheme.titleSmall), // TODO(l10n): 补 arb
          RadioGroup<BomImportMode>(
            groupValue: _mode,
            onChanged: (v) => setState(() => _mode = v ?? BomImportMode.replace),
            child: const Column(
              children: [
                RadioListTile<BomImportMode>(
                  value: BomImportMode.replace,
                  title: Text('按文件为准（替换各级现有组件）'), // TODO(l10n): 补 arb
                  dense: true,
                ),
                RadioListTile<BomImportMode>(
                  value: BomImportMode.append,
                  title: Text('在现有组件后追加'), // TODO(l10n): 补 arb
                  dense: true,
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s8),
        TextButton(
          onPressed: _pickAndDetect,
          child: const Text('重新选择文件'), // TODO(l10n): 补 arb
        ),
      ],
    );
  }
}
