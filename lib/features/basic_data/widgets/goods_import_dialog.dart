// 货品批量导入流程弹窗：选文件 → 检测 → 报告（错误/将自动新建）→ 确认导入 → 结果。
//
// 两段式（先检测后导入）：检测出的硬错误（编号空/重复/已存在、必填缺失、引用歧义）会拦住
// 提交，让用户改完重传；无错才允许「确认导入」。提交是后端原子事务（缺分类/颜色/单位自动
// 新建，编号查重命中整批回滚），绝不「传一半」。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../models/goods_import.dart';
import '../repositories/goods_import_repository.dart';
import 'goods_import_file_reader.dart';

/// 弹出导入流程。[onImported] 在导入成功后回调（调用方刷新货品列表）。
Future<void> showGoodsImportDialog(
  BuildContext context,
  WidgetRef ref, {
  VoidCallback? onImported,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 580,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
        ),
        child: _GoodsImportDialog(onImported: onImported),
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
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
                  onPressed: () => Navigator.of(context).pop(),
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
    );
  }

  Widget _body(ThemeData theme) {
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
    // 初始：选文件 + 格式说明
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('选择未加密的 .xlsx 文件，系统会先检测再导入。', style: theme.textTheme.bodyMedium),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '必填列：编号、类别（用 - 拼分类路径）、货品名称。\n'
          '可选列：系列、型号、规格、材质、主颜色、单位、来源、价格、状态。\n'
          '缺失的分类/颜色/单位会自动新建；编号重复或已存在会拦下，改完再传。\n'
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
            '$title（${items.length}）：${items.take(20).join("、")}${items.length > 20 ? " …" : ""}',
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
        if (canConfirm)
          UtenButton(
            icon: Icons.check_rounded,
            onPressed: _commit,
            child: const Text('确认导入'),
          ),
      ],
    );
  }

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
          .read(goodsImportRepositoryProvider)
          .detect(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _pickedName = f.name;
        _report = report;
        _result = null;
        _detecting = false;
      });
    } on GoodsImportFileException catch (e) {
      if (!mounted) return;
      setState(() => _detecting = false);
      context.appError(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _detecting = false);
      context.appApiError(
        e,
        fallback: 'Excel 文件选择或检测异常，请刷新页面后重试；仍失败请联系管理员重启 Web 服务',
      );
    }
  }

  Future<void> _commit() async {
    final bytes = _bytes;
    final planId = _report?.planId;
    if (bytes == null || planId == null || planId.isEmpty) {
      context.appError('检测计划已失效，请重新选择文件并检测');
      return;
    }
    setState(() => _committing = true);
    try {
      final res = await ref
          .read(goodsImportRepositoryProvider)
          .commit(bytes, planId: planId, filename: _pickedName);
      if (!mounted) return;
      setState(() {
        _result = res;
        _committing = false;
      });
      context.appSuccess('已导入 ${res.importedCount} 条货品');
      widget.onImported?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _committing = false);
      context.appApiError(e);
    }
  }
}
