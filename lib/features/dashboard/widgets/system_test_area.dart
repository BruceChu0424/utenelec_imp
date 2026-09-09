// SystemTestArea - 工作台底部「系统测试」区（仅超级管理员可见）
//
// 当前只有一张「清空数据」卡：把本地开发库/内网测试服务器库重置为
// 「保留基础资料与人事权限、业务数据从 1 重新开始」的干净测试起点。
// 口径与 server/ops/reset_business_data.sql（psql 停机版）一致，由后端
// V462 函数 + BusinessDataResetService 执行（见 ADR-067）：
//   · 保留：基础资料（货品/客户/供应商/账户/仓库…）、人事、账号权限、审计日志；
//   · 清空：销售/采购/委外/生产/仓库/财务全部业务单据、明细、流水、预留、核销，
//     ID 与业务编号序列从 1 重新开始；库存、账户余额、各类期初全部归零；
//   · 完成后全员（含当前账号）强制下线，需重新登录。
// 安全门禁（后端）：运行开关（仅 dev / internal-test）+ 超管 + 输入口令 +
// 排水闸；公司目标库（prod）默认拒绝执行。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../repositories/system_test_repository.dart';
import 'business_attachment_reset_dialog.dart';

class SystemTestArea extends ConsumerStatefulWidget {
  const SystemTestArea({super.key});

  @override
  ConsumerState<SystemTestArea> createState() => _SystemTestAreaState();
}

class _SystemTestAreaState extends ConsumerState<SystemTestArea> {
  @override
  Widget build(BuildContext context) {
    // 工作台卡片显隐复用路由权限映射；本区是超管专属测试工具，不走权限码。
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    if (!isSuperAdmin) return const SizedBox.shrink();

    return UtenCollapsibleSection(
      title: '系统测试',
      accentColor: UtenColors.error,
      // 危险区默认收起：标题常驻可见，避免误触。
      initiallyExpanded: false,
      // 单卡仍走与功能模块区相同的响应式网格，卡片尺寸/换行与其它工作台卡片一致。
      child: UtenResponsiveGrid(
        itemCount: 1,
        spacing: UtenSpacing.s12,
        columns: const UtenResponsiveColumns(compact: 2, medium: 3),
        itemBuilder: (context, index, itemWidth) => const _ClearDataCard(),
      ),
    );
  }
}

class _ClearDataCard extends ConsumerWidget {
  const _ClearDataCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 与功能模块区 _ModuleTile 同款卡片：图标块 + 标题，整卡点击弹确认窗；
    // 唯一差别是红色警示配色（本区是破坏性测试工具）。说明全部收进弹窗。
    return Material(
      type: MaterialType.transparency,
      borderRadius: UtenRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('system-test-clear-data-card'),
        onTap: () => _openConfirmDialog(context, ref),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            vertical: UtenSpacing.s16,
            horizontal: UtenSpacing.s12,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: UtenRadius.lgAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: UtenColors.error.withValues(alpha: 0.1),
                  borderRadius: UtenRadius.mdAll,
                ),
                child: const Icon(
                  Icons.delete_sweep_outlined,
                  color: UtenColors.error,
                  size: 19,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  '清空数据',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openConfirmDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _ClearConfirmDialog(
        onConfirmed: (result) => _handleCleared(context, ref, result),
        onError: (message) => _handleError(context, message),
      ),
    );
  }

  Future<void> _handleCleared(
    BuildContext context,
    WidgetRef ref,
    BusinessDataResetResult result,
  ) async {
    // 会话已被服务端作废（epoch 已递增、refresh token 已清空），
    // 这里主动本地登出并回登录页；通知先弹给用户再离开当前页。
    context.appSuccess(
      '已清空 ${result.clearedTableCount} 张业务表'
      '（${result.clearedRows} 行），保留 ${result.preservedTableCount} 张主档；'
      '请重新登录',
      title: '业务数据已清空',
    );
    await ref.read(sessionProvider.notifier).logout();
    if (context.mounted) {
      context.go(RouteName.login);
    }
  }

  void _handleError(BuildContext context, String message) {
    context.appError(message, title: '清空失败');
  }
}

class _ClearConfirmDialog extends ConsumerStatefulWidget {
  const _ClearConfirmDialog({required this.onConfirmed, required this.onError});

  final ValueChanged<BusinessDataResetResult> onConfirmed;
  final ValueChanged<String> onError;

  @override
  ConsumerState<_ClearConfirmDialog> createState() =>
      _ClearConfirmDialogState();
}

class _ClearConfirmDialogState extends ConsumerState<_ClearConfirmDialog> {
  static const _confirmPhrase = '清空业务数据';

  final TextEditingController _controller = TextEditingController();
  bool _running = false;
  bool _checkingFiles = true;
  BusinessAttachmentResetPreview? _files;
  String? _fileError;

  @override
  void initState() {
    super.initState();
    Future.microtask(_checkFiles);
  }

  Future<void> _checkFiles() async {
    setState(() {
      _checkingFiles = true;
      _fileError = null;
      _files = null;
    });
    try {
      final value = await ref
          .read(systemTestRepositoryProvider)
          .previewBusinessAttachments();
      if (mounted) setState(() => _files = value);
    } catch (_) {
      if (mounted) setState(() => _fileError = '无法核对业务附件，暂时不能清空。请重试。');
    } finally {
      if (mounted) setState(() => _checkingFiles = false);
    }
  }

  Future<void> _prepareFiles() async {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BusinessAttachmentResetDialog(),
    );
    if (mounted) await _checkFiles();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _confirmed =>
      _controller.text.trim() == _confirmPhrase &&
      !_checkingFiles &&
      _files?.blockingCount == 0;

  Future<void> _submit() async {
    if (!_confirmed || _running) return;
    setState(() => _running = true);
    try {
      final result = await ref
          .read(systemTestRepositoryProvider)
          .resetBusinessData();
      if (!mounted) return;
      Navigator.of(context).pop();
      widget.onConfirmed(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _running = false);
      widget.onError(error.message);
    } catch (error) {
      if (!mounted) return;
      setState(() => _running = false);
      widget.onError('清空请求失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      key: const Key('system-test-clear-confirm-dialog'),
      title: const Text('清空业务数据'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('即将在本环境执行不可恢复的清空（不创建备份）：', style: theme.textTheme.bodyMedium),
            if (_checkingFiles) const LinearProgressIndicator(),
            if (_fileError != null) Text(_fileError!),
            if (_fileError != null)
              TextButton(onPressed: _checkFiles, child: const Text('重新核对附件')),
            if ((_files?.blockingCount ?? 0) > 0) ...[
              Text('还有 ${_files!.blockingCount} 项业务文件或删除任务未完成，先处理附件后才能清空。'),
              TextButton.icon(
                onPressed: _running ? null : _prepareFiles,
                icon: const Icon(Icons.folder_delete_outlined),
                label: const Text('先清理业务附件'),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            ...[
              '保留：基础资料（货品/客户/供应商/账户/仓库…）、人事、账号权限、审计日志',
              '清空：销售/采购/委外/生产/仓库/财务全部业务单据、明细、流水、预留、核销',
              '归零：库存、账户期初/累计收款/累计付款/累计调整/当前余额、各类期初往来',
              '重排：业务表自增 ID 与编号序列从 1 重新开始',
              '下线：所有人（含当前账号）立即退出，需重新登录',
            ].map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: UtenColors.warning,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(
                      child: Text(
                        line,
                        style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '请输入「$_confirmPhrase」确认：',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              key: const Key('system-test-clear-confirm-input'),
              controller: _controller,
              enabled: !_running,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '清空业务数据',
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: _running ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('system-test-clear-confirm-submit'),
          type: UtenButtonType.danger,
          onPressed: (_confirmed && !_running) ? _submit : null,
          child: _running
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('确认清空'),
        ),
      ],
    );
  }
}
