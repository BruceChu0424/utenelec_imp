// NoticePopupSettingsDialog —— 个人通知弹窗开关（V833/ADR-171）。
//
// 工作台右上角「通知设置」入口弹出的居中对话框：列出本人当前会收到的弹窗提醒
// 类别（服务端按弹卡资格 ∪ 审核目录下发中文名），逐类开关；关闭后该类通知不再弹
// （居中行动卡与顶部到达条都不再出现），通知仍保留在通知中心、未读徽章照常。
//
// 交互口径：
// - 开关即时保存（每行独立 busy，失败回滚本地状态并提示重试）；
// - 列表=当前资格：调部门/收回权限后自动收窄，历史关闭行不再展示（无害）；
// - 人事打卡与运维/账号安全告警不在此列（强制动作/面向超管，不开放关闭）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../providers/notice_providers.dart';
import '../repositories/notice_repository.dart';

/// 弹出「通知设置」对话框（挂根 Navigator，与审核弹窗同层）。
Future<void> showNoticePopupSettingsDialog(BuildContext context) {
  return showDialog(
    context: context,
    builder: (context) => const _NoticePopupSettingsDialog(),
  );
}

class _NoticePopupSettingsDialog extends ConsumerStatefulWidget {
  const _NoticePopupSettingsDialog();

  @override
  ConsumerState<_NoticePopupSettingsDialog> createState() =>
      _NoticePopupSettingsDialogState();
}

class _NoticePopupSettingsDialogState
    extends ConsumerState<_NoticePopupSettingsDialog> {
  List<NoticePopupPreference>? _prefs;
  bool _loadFailed = false;
  final Set<String> _saving = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loadFailed = false;
      _prefs = null;
    });
    try {
      final prefs = await ref.read(noticeRepositoryProvider).popupPreferences();
      if (!mounted) return;
      setState(() => _prefs = prefs);
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  Future<void> _toggle(NoticePopupPreference pref, bool enabled) async {
    if (_saving.contains(pref.sourceEvent)) return;
    setState(() => _saving.add(pref.sourceEvent));
    try {
      await ref
          .read(noticeRepositoryProvider)
          .setPopupPreference(pref.sourceEvent, disabled: !enabled);
      if (!mounted) return;
      setState(() {
        _prefs = _prefs
            ?.map(
              (item) => item.sourceEvent == pref.sourceEvent
                  ? NoticePopupPreference(
                      sourceEvent: item.sourceEvent,
                      label: item.label,
                      applicable: item.applicable,
                      popupDisabled: !enabled,
                    )
                  : item,
            )
            .toList();
      });
    } catch (_) {
      if (!mounted) return;
      // 失败回滚（本地未变更），提示重试；开关保持原值。
      context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving.remove(pref.sourceEvent));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s24,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s20,
            UtenSpacing.s16,
            UtenSpacing.s12,
            UtenSpacing.s16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '通知设置',
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '关闭后该类通知不再弹窗提醒；通知仍保留在通知中心，未读徽章照常显示。',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () =>
                        Navigator.of(context, rootNavigator: true).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Flexible(child: _body(theme)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loadFailed) {
      return _panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败', style: theme.textTheme.bodyMedium),
            const SizedBox(height: UtenSpacing.s8),
            TextButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final prefs = _prefs;
    if (prefs == null) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // 2026-10-09 用户口径：通知页设置「全部通知类型」——分「我会收到的弹窗」（可开关，
    // = 当前弹卡资格：真实授出权限 ∩ 部门/对象归属）与「其它类别」（当前岗位不会收到，
    // 仅浏览）两组；我该收什么由资格决定，不由列表决定。
    final mine = prefs.where((item) => item.applicable).toList();
    final others = prefs.where((item) => !item.applicable).toList();
    return _panel(
      child: ListView(
        shrinkWrap: true,
        children: [
          _sectionHeader(theme, '我会收到的弹窗', mine.length),
          if (mine.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Text(
                '当前没有会弹窗提醒的类别；获得新的任务权限后会自动出现。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            )
          else
            for (final pref in mine) _applicableRow(theme, pref),
          if (others.isNotEmpty) ...[
            _sectionHeader(theme, '其它类别（当前岗位不会收到）', others.length),
            for (final pref in others)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        pref.label.isEmpty ? pref.sourceEvent : pref.label,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Icon(
                      Icons.block_rounded,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _sectionHeader(ThemeData theme, String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        UtenSpacing.s4,
      ),
      child: Text(
        '$title（$count）',
        style: theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _applicableRow(ThemeData theme, NoticePopupPreference pref) {
    final enabled = !pref.popupDisabled;
    final busy = _saving.contains(pref.sourceEvent);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              pref.label.isEmpty ? pref.sourceEvent : pref.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Semantics(
            label: '${pref.label}弹窗提醒',
            button: true,
            child: Switch(
              key: ValueKey('popup-pref-switch-${pref.sourceEvent}'),
              value: enabled,
              onChanged: busy ? null : (value) => _toggle(pref, value),
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel({required Widget child}) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 420),
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}
