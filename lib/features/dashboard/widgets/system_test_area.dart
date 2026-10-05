// SystemTestArea - 工作台底部「系统测试」区(仅超级管理员可见)
//
// 当前只有一张「清空数据」卡：把本地开发库/内网测试服务器库重置为
// 「保留基础资料与人事权限、业务数据从 1 重新开始」的干净测试起点。
// 这里是清空的唯一入口，由后端 business_data_reset() + BusinessDataResetService
// 执行(见 ADR-067、ADR-155)：
//   · 保留：基础资料(货品/客户/供应商/账户/仓库…)、人事、账号权限与配置；
//   · 清空：销售/采购/委外/生产/仓库/财务全部业务单据、明细、流水、预留、核销，
//     ID 与业务编号序列从 1 重新开始；库存、账户余额、各类期初全部归零；
//   · 测试文件：哪些文件属于测试数据只由服务端一条规则决定(人事档案/合同、货品、
//     成本导入原件和已采用的报价模板永不删除)。弹窗一打开就调用与清空同一个检查，
//     显示将删除的文件计数和现在不能清空的原因(服务端原文，逐条显示)，有原因时禁用确认；
//     服务端在排水前再查一次，清空事务里加锁后、删除任何文件之前再查一次，然后删除并清库；
//   · 完成后全员(含当前账号)强制下线，需重新登录。
// 安全门禁(后端)：运行开关(dev / internal-test 及内网公司服务器测试期开启；云端一律拒绝)
// + 超管本人 + 再认证 + 输入口令 + 排水闸。
// 时序：清空是同步长请求(受理后 5 分钟内完成检查、排水和删除测试文件，之后清库)，本端点
// 接收超时 10 分钟(网关同步放宽)；仍超时则提示「可能仍在后台执行」，重登后本区回显上次结果。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../repositories/system_test_repository.dart';

class SystemTestArea extends ConsumerStatefulWidget {
  const SystemTestArea({super.key});

  @override
  ConsumerState<SystemTestArea> createState() => _SystemTestAreaState();
}

class _SystemTestAreaState extends ConsumerState<SystemTestArea> {
  /// History is shown when expanded; an unresolved receipt and read failures
  /// remain visible even with the danger controls collapsed.
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // 工作台卡片显隐复用路由权限映射；本区是超管专属测试工具，不走权限码。
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    if (!isSuperAdmin) return const SizedBox.shrink();

    final pending = ref.watch(pendingBusinessDataResetProvider);
    final last = ref.watch(lastBusinessDataResetResultProvider);
    final showOutside =
        pending.asData?.value != null ||
        pending.hasError ||
        last.hasError ||
        last.asData?.value.confirmedPendingAttempt == true;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenCollapsibleSection(
          title: '系统测试',
          accentColor: UtenColors.error,
          // 危险区默认收起：标题常驻可见，避免误触。
          initiallyExpanded: false,
          onExpandedChanged: (expanded) => setState(() => _expanded = expanded),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 单卡仍走与功能模块区相同的响应式网格，卡片尺寸/换行与其它工作台卡片一致。
              UtenResponsiveGrid(
                itemCount: 1,
                spacing: UtenSpacing.s12,
                columns: const UtenResponsiveColumns(compact: 2, medium: 3),
                itemBuilder: (context, index, itemWidth) =>
                    const _ClearDataCard(),
              ),
              if (_expanded && !showOutside) const _LastResetResultLine(),
            ],
          ),
        ),
        if (showOutside) const _LastResetResultLine(),
      ],
    );
  }
}

/// 成功提示与上次结果里的死信条数(没有就不提)。
String _deadEventsCleared(int events) =>
    events > 0 ? '，清除失败的后台事件 $events 条' : '';

/// 将删除的测试文件计数：按来源类别列出非零份数，再给出存储位置的实地核对结果。
/// 服务端这次没有核对存储时不报「还在 / 已经不在」的个数(那是 0，不是核对结果)。
String _previewFilesLine(BusinessDataResetPreview preview) {
  final kinds = preview.kinds
      .where((kind) => kind.files > 0)
      .map((kind) => '${kind.label} ${kind.files} 份')
      .join('、');
  final inspected = preview.inspectionSkipped
      ? '(共 ${preview.locations} 个存储位置；这次没有核对它们是否还在存储里，'
            '${preview.refused ? '先处理上面的问题，再' : ''}点「重新检查」核对)。'
      : '(共 ${preview.locations} 个存储位置：${preview.presentFiles} 个文件还在存储里，'
            '将被删除；${preview.absentFiles} 个已经不在)。';
  return '将一并物理删除测试文件：$kinds$inspected'
      '人事档案/合同、货品图片/图纸、成本导入原件和已采用的报价模板不会删除。';
}

/// 预览被这些错误码拒绝时，清空会被服务端以同样原因拒绝：显示服务端原话并禁用确认。
///   · FORBIDDEN：运行开关未开启、模拟他人身份、不是在职超管本人；
///   · RESET_SERVER_MISCONFIGURED：服务器数据库账号或清空程序配置有误，要开发人员处理。
const _previewBlockingCodes = {'FORBIDDEN', 'RESET_SERVER_MISCONFIGURED'};

/// 处理失败、已停止重试的后台事件会随清空清除：按类别报条数。
String _previewDeadEventsLine(BusinessDataResetPreview preview) {
  final groups = preview.deadBackgroundEvents.where((item) => item.events > 0);
  final kinds = groups
      .map((item) => '${item.label} ${item.events} 条')
      .join('、');
  final weightRefresh = groups.any((item) => item.label == '货品单重重算')
      ? '货品单重估算如果因此没有更新，每晚 2 点 13 分会自动补算。'
      : '';
  return '另有 ${preview.deadBackgroundEventCount} 条处理失败、已停止重试的后台事件'
      '会一并清除($kinds)。$weightRefresh';
}

/// 上次清空结果回显（重登后可见）：清空请求在客户端/网关超时后服务端仍会完成并
/// 踢人，这里让发起人确认「已成功但断连」还是真的失败。
/// A pending reset is reconciled even when the danger section is collapsed.
/// Read errors remain visible: absence of a response is not proof of failure.
class _LastResetResultLine extends ConsumerWidget {
  const _LastResetResultLine();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final waiting =
        ref.watch(pendingBusinessDataResetProvider).asData?.value != null;
    Widget retry(String message) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          key: const Key('system-test-reset-result-warning'),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
        ),
        TextButton(
          key: const Key('system-test-last-reset-retry'),
          onPressed: () {
            ref.invalidate(lastBusinessDataResetResultProvider);
            ref.invalidate(pendingBusinessDataResetProvider);
          },
          child: const Text('重新核对结果'),
        ),
      ],
    );
    return ref
        .watch(lastBusinessDataResetResultProvider)
        .when(
          loading: () => const Text('正在核对清空完成记录…'),
          error: (error, _) => retry(
            '无法读取清空完成记录：${error is ApiException ? error.message : '请检查连接后重试'}'
            '${waiting ? '。结果仍待确认，请勿再次提交。' : ''}',
          ),
          data: (result) {
            // 服务端受理回执已确定本次请求没有执行（未收到 / 已拒绝 / 进程重启回滚）：
            // 本地待确认记录已撤销，明确告知可以重新提交（ADR-067 §9）。
            final retiredReason = result.retiredPendingReason;
            if (retiredReason != null) {
              final end = retiredReason.endsWith('。') ? '' : '。';
              return Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s8),
                child: Text(
                  '$retiredReason$end本地待确认记录已撤销，现在可以重新提交清空。',
                  key: const Key('system-test-reset-retired-notice'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: UtenColors.warning,
                  ),
                ),
              );
            }
            if (!result.available) {
              return waiting
                  ? retry(
                      result.attemptReceived
                          ? '服务器已受理本次清空、尚未完成，可能仍在执行。请稍后核对，不要再次提交。'
                          : '尚未查到本次清空的受理记录，正在核对是否已送达。请稍后核对，不要再次提交。',
                    )
                  : const SizedBox.shrink();
            }
            final finishedAt = result.finishedAt;
            final when = finishedAt == null
                ? ''
                : '${ChinaDateTime.formatInstant(finishedAt)} ';
            return Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (waiting && !result.confirmedPendingAttempt)
                    retry('这条记录未匹配本次请求的操作者和关联 ID，尚不能确认本次清空。请勿再次提交。'),
                  Text(
                    '${result.confirmedPendingAttempt ? '本次清空已确认' : '上次清空'}：$when由 ${result.operatorAccount ?? '—'} 执行，'
                    '清空 ${result.clearedTableCount} 张业务表(${result.clearedRows} 行)，'
                    '保留 ${result.preservedTableCount} 张主档，'
                    '物理删除测试文件 ${result.deletedAttachmentFiles} 个'
                    '${_deadEventsCleared(result.deadBackgroundEventsCleared)}',
                    key: const Key('system-test-last-reset-result'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            );
          },
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
        onPending: (message) => _handlePending(context, message),
      ),
    );
  }

  Future<void> _handleCleared(
    BuildContext context,
    WidgetRef ref,
    BusinessDataResetResult result,
  ) async {
    if (!context.mounted) return;
    // 会话已被服务端作废（epoch 已递增、refresh token 已清空），
    // 这里主动本地登出并回登录页；通知先弹给用户再离开当前页。
    context.appSuccess(
      '已清空 ${result.clearedTableCount} 张业务表'
      '(${result.clearedRows} 行)，保留 ${result.preservedTableCount} 张主档，'
      '物理删除测试文件 ${result.deletedAttachmentFiles} 个'
      '${_deadEventsCleared(result.deadBackgroundEventsCleared)}；请重新登录',
      title: '业务数据已清空',
    );
    await ref.read(sessionProvider.notifier).logout();
    if (context.mounted) {
      context.go(RouteName.login);
    }
  }

  void _handleError(BuildContext context, String message) {
    if (!context.mounted) return;
    context.appError(message, title: '清空失败');
  }

  /// 客户端/网关超时 ≠ 失败：服务端不感知断连、会继续执行完并把全员踢下线。
  void _handlePending(BuildContext context, String message) {
    if (!context.mounted) return;
    context.appWarning(message, title: '清空结果待确认');
  }
}

class _ClearConfirmDialog extends ConsumerStatefulWidget {
  const _ClearConfirmDialog({
    required this.onConfirmed,
    required this.onError,
    required this.onPending,
  });

  final ValueChanged<BusinessDataResetResult> onConfirmed;
  final ValueChanged<String> onError;
  final ValueChanged<String> onPending;

  @override
  ConsumerState<_ClearConfirmDialog> createState() =>
      _ClearConfirmDialogState();
}

class _ClearConfirmDialogState extends ConsumerState<_ClearConfirmDialog> {
  static const _confirmPhrase = '清空业务数据';

  final TextEditingController _controller = TextEditingController();
  bool _running = false;
  bool _awaitingConfirmation = false;
  bool _checking = true;

  /// 只认最近一次检查的结果：连点「重新检查」时，先发出的慢请求不能覆盖后来的结果。
  int _checkGeneration = 0;

  /// 预览被 [_previewBlockingCodes] 拒绝：清空会被后端同样拒绝，显示后端原话并保持禁用。
  /// 其它预览失败(503/超时/网络)不禁用——清空时服务端会在删除任何文件之前再检查一次。
  bool _previewBlocked = false;
  BusinessDataResetPreview? _preview;
  String? _previewError;

  /// 上次提交被服务端明确拒绝或中断时的原文(可能含文件名与已删数)，留在弹窗里可复制。
  String? _submitError;

  /// 上次提交因客户端/网关超时中断时的提示（弹窗保持打开，用户须留在此观察）。
  String? _timeoutHint;

  @override
  void initState() {
    super.initState();
    Future.microtask(_checkReset);
  }

  /// 调用与清空同一个检查(只读)：将删除的测试文件计数 + 现在不能清空的原因。
  Future<void> _checkReset() async {
    if (!mounted) return;
    final generation = ++_checkGeneration;
    setState(() {
      _checking = true;
      _previewBlocked = false;
      _previewError = null;
      _preview = null;
    });
    bool current() => mounted && generation == _checkGeneration;
    try {
      final value = await ref
          .read(systemTestRepositoryProvider)
          .previewBusinessDataReset();
      if (current()) setState(() => _preview = value);
    } on ApiException catch (error) {
      if (!current()) return;
      setState(() {
        _previewBlocked = _previewBlockingCodes.contains(error.code);
        _previewError = error.message;
      });
    } catch (_) {
      if (current()) setState(() => _previewError = '没有收到服务器的核对结果');
    } finally {
      if (current()) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  // 按钮亮灯：口令 + 检查已结束 + 预览没被拒绝(见 _previewBlockingCodes) + 预览没有列出拒绝原因。
  // 预览失败或超时仍可提交：服务端排水前、删除任何文件之前都会用同一个检查再查一次。
  bool get _confirmed =>
      _controller.text.trim() == _confirmPhrase &&
      !_checking &&
      !_previewBlocked &&
      !(_preview?.refused ?? false) &&
      !_awaitingConfirmation &&
      !ref.read(pendingBusinessDataResetProvider).isLoading &&
      !ref.read(pendingBusinessDataResetProvider).hasError &&
      ref.read(pendingBusinessDataResetProvider).asData?.value == null;

  Future<void> _submit() async {
    if (!_confirmed || _running) return;
    setState(() {
      _running = true;
      _timeoutHint = null;
      _submitError = null;
    });
    try {
      final result = await ref
          .read(systemTestRepositoryProvider)
          .resetBusinessData();
      if (!mounted) return;
      ref.invalidate(pendingBusinessDataResetProvider);
      Navigator.of(context).pop();
      widget.onConfirmed(result);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (isBusinessDataResetOutcomeUncertain(error)) {
        _showPending();
        return;
      }
      // 先撤遮罩再提示：服务端原文留在弹窗里，随后按同一个检查刷新拒绝原因。
      setState(() {
        _running = false;
        _submitError = error.message;
      });
      ref.invalidate(pendingBusinessDataResetProvider);
      widget.onError(error.message);
      await _checkReset();
    } catch (_) {
      if (!mounted) return;
      _showPending();
    }
  }

  void _showPending() {
    const hint = '清空可能仍在后台执行，也可能已经完成。结果待确认，请勿再次提交；重新登录后将核对本次关联记录。';
    setState(() {
      _running = false;
      _awaitingConfirmation = true;
      _timeoutHint = hint;
    });
    ref.invalidate(pendingBusinessDataResetProvider);
    ref.invalidate(lastBusinessDataResetResultProvider);
    widget.onPending(hint);
  }

  Widget _panel({
    required Key key,
    required Color color,
    required List<Widget> children,
  }) => Container(
    key: key,
    width: double.infinity,
    margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
    padding: const EdgeInsets.all(UtenSpacing.s8),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.06),
      borderRadius: UtenRadius.mdAll,
      border: Border.all(color: color.withValues(alpha: 0.4)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    ),
  );

  /// 清空前检查结果：核对中 / 预览失败 / 拒绝原因(服务端原文逐条) / 文件计数与提醒。
  List<Widget> _resetCheckSection(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(height: 1.4);
    final muted = small?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final error = theme.colorScheme.error;
    final recheck = Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const Key('system-test-reset-recheck'),
        onPressed: _running ? null : _checkReset,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('重新检查'),
      ),
    );
    if (_checking) {
      return [
        const LinearProgressIndicator(),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '正在核对测试文件…',
          key: const Key('system-test-reset-checking'),
          style: muted,
        ),
      ];
    }
    final previewError = _previewError;
    if (previewError != null) {
      return [
        Text(
          _previewBlocked
              ? previewError
              : '无法预先核对测试文件($previewError)。清空时服务器会再次核对，仍可提交。',
          key: const Key('system-test-reset-preview-error'),
          style: _previewBlocked ? small?.copyWith(color: error) : small,
        ),
        recheck,
      ];
    }
    final preview = _preview;
    if (preview == null) return const [];
    return [
      if (preview.refused)
        _panel(
          key: const Key('system-test-reset-refusals'),
          color: error,
          children: [
            Text(
              '现在不能清空，原因如下：',
              style: small?.copyWith(color: error, fontWeight: FontWeight.w600),
            ),
            for (final refusal in preview.refusals)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s4),
                child: SelectableText(refusal.message, style: small),
              ),
          ],
        ),
      if (preview.locations > 0) ...[
        Text(
          _previewFilesLine(preview),
          key: const Key('system-test-reset-preview-files'),
          style: muted,
        ),
        if (!preview.inspectionComplete && !preview.inspectionSkipped)
          Text(
            '文件较多，预先只核对了 ${preview.inspectedObjects} / ${preview.locations} 个；'
            '其余会在清空时核对，有问题会在删除任何文件之前停下并说明原因。',
            key: const Key('system-test-reset-preview-partial'),
            style: muted,
          ),
        if (preview.allListedMissing)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: _panel(
              key: const Key('system-test-reset-all-missing'),
              color: UtenColors.warning,
              children: [
                Text(
                  '登记的 ${preview.locations} 个测试文件在存储里一个都没找到。'
                  '如果服务器的附件存储盘没有挂载好，请先让维护人员检查；'
                  '否则清空后这些文件会留在存储盘里，以后只能靠附件对账找出来。',
                  style: small?.copyWith(
                    color: UtenColors.warning,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ] else
        Text(
          '没有需要删除的测试文件。',
          key: const Key('system-test-reset-preview-none'),
          style: muted,
        ),
      if (preview.deadBackgroundEventCount > 0)
        Text(
          _previewDeadEventsLine(preview),
          key: const Key('system-test-reset-dead-events'),
          style: muted,
        ),
      recheck,
    ];
  }

  /// 提交后被服务端明确拒绝或中断：原文留在弹窗里(可能含文件名、已删数和下一步)。
  Widget _submitErrorBlock(ThemeData theme) {
    final small = theme.textTheme.bodySmall?.copyWith(height: 1.4);
    return _panel(
      key: const Key('system-test-reset-submit-error'),
      color: theme.colorScheme.error,
      children: [
        Text(
          '本次清空没有完成，服务器的说明：',
          style: small?.copyWith(
            color: theme.colorScheme.error,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        SelectableText(_submitError ?? '', style: small),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pending = ref.watch(pendingBusinessDataResetProvider);
    final last = ref.watch(lastBusinessDataResetResultProvider);
    // 服务端受理回执确定本次请求没有执行后（ADR-067 §9），弹窗内的等待态一并解除，
    // 口令仍在就能直接重新提交，不必关掉重开。
    ref.listen(lastBusinessDataResetResultProvider, (_, next) {
      if (_awaitingConfirmation &&
          next.asData?.value.retiredPendingReason != null) {
        setState(() {
          _awaitingConfirmation = false;
          _timeoutHint = null;
        });
      }
    });
    final awaiting =
        _awaitingConfirmation ||
        pending.asData?.value != null ||
        pending.hasError ||
        last.asData?.value.retiredPendingReason != null;
    return AlertDialog(
      key: const Key('system-test-clear-confirm-dialog'),
      title: const Text('清空业务数据'),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 清空执行期间的全屏加载遮罩（root Overlay 传送门，不占布局）。
              if (_running)
                const UtenBusyOverlay(
                  title: '正在清空业务数据',
                  description: '正在核对并删除测试文件、清空业务数据，耗时较长，请勿关闭弹窗或离开页面。',
                ),
              Text(
                '即将在本环境执行不可恢复的清空（不创建备份）：',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: UtenSpacing.s8),
              ..._resetCheckSection(theme),
              if (_submitError != null) _submitErrorBlock(theme),
              const SizedBox(height: UtenSpacing.s12),
              ...[
                '保留：基础资料（货品/客户/供应商/账户/仓库…）、人事、账号权限与配置',
                '清空：销售/采购/委外/生产/仓库/财务全部测试业务数据、删除历史、字段版本和历史审计记录（含登录及主档操作）；清空操作的核对凭据保留',
                '删除：测试业务文件(业务附件、上传中的文件、AI识别原件、报价模板候选)随清空物理删除；人事档案/合同、货品图片/图纸、成本导入原件和已采用的报价模板不删除',
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
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.4,
                          ),
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
              if (_timeoutHint != null)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: Text(
                    last.asData?.value.confirmedPendingAttempt == true
                        ? '已确认服务器完成清空，请关闭此窗口；无需再次提交。'
                        : _timeoutHint!,
                    key: const Key('system-test-clear-timeout-hint'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: UtenColors.warning,
                    ),
                  ),
                ),
              if (awaiting) const _LastResetResultLine(),
            ],
          ),
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
