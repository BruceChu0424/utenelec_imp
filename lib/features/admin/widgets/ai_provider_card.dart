// AI 服务卡片(可折叠): 头部常显(头像/名称/模型/区域·默认徽章/启停开关), 点头部展开
// 模型/地址/密钥掩码/上次测试 + 连接测试结果 + 操作按钮。
//
// 密钥只显示服务端给的掩码(「••••abcd」/「已配置」), 本卡片拿不到也不显示原文。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/ai/ai_tone.dart';
import '../models/ai_provider_models.dart';
import 'ai_connection_test_view.dart';
import 'ai_masked_key.dart';
import 'ai_settings_labels.dart';

/// 卡片与表头统一的操作按钮高度(适老化: 触控目标不小于 48)。
const double aiSettingsActionHeight = 48;

class AiProviderCard extends StatefulWidget {
  const AiProviderCard({
    super.key,
    required this.provider,
    required this.preset,
    required this.presetLabel,
    required this.busy,
    required this.testing,
    required this.testResult,
    required this.canDelete,
    required this.onTest,
    required this.onEdit,
    required this.onSetDefault,
    required this.onDelete,
    required this.onEnabledChanged,
    this.initiallyExpanded,
  });

  final AiProviderConfig provider;
  final AiProviderPreset? preset;
  final String presetLabel;

  /// 页面正在执行其它保存; 卡片操作暂不可点。
  final bool busy;
  final bool testing;
  final AiConnectionTestResult? testResult;

  /// 默认服务只有在它是最后一个时才能删除(与服务端规则一致)。
  final bool canDelete;
  final VoidCallback onTest;
  final VoidCallback onEdit;
  final VoidCallback onSetDefault;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEnabledChanged;

  /// 默认收起: 服务多时一屏只看「谁在用、开没开」, 要管理再展开。
  final bool? initiallyExpanded;

  @override
  State<AiProviderCard> createState() => _AiProviderCardState();
}

class _AiProviderCardState extends State<AiProviderCard> {
  late bool _expanded = widget.initiallyExpanded ?? false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final provider = widget.provider;
    final keyNotNeeded = !provider.keyRequiredWith(widget.preset);
    return UtenCard(
      key: ValueKey('ai-provider-card-${provider.id}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部(常显): 点任意处展开/收起; 启停开关自己消化点按, 不会连带展开。
          Material(
            color: Colors.transparent,
            child: InkWell(
              key: ValueKey('ai-provider-header-${provider.id}'),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Semantics(
                button: true,
                expanded: _expanded,
                label: provider.name,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s2),
                  child: Row(
                    children: [
                      AiProviderAvatar(
                        label: widget.presetLabel,
                        region: provider.region,
                        dimmed: !provider.enabled,
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              provider.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Wrap(
                              spacing: UtenSpacing.s6,
                              runSpacing: UtenSpacing.s4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  provider.model,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                Text(
                                  widget.presetLabel,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                UtenStatusBadge(
                                  label: provider.region.label(l10n),
                                  type: provider.region.badgeType,
                                  size: UtenStatusBadgeSize.small,
                                ),
                                if (provider.isDefault)
                                  UtenStatusBadge(
                                    key: const ValueKey(
                                      'ai-provider-default-badge',
                                    ),
                                    label: l10n.aiSettingsDefaultBadge,
                                    type: UtenStatusBadgeType.success,
                                    icon: Icons.star_rounded,
                                    size: UtenStatusBadgeSize.small,
                                  ),
                                if (!provider.enabled)
                                  UtenStatusBadge(
                                    label: l10n.aiSettingsDisabledBadge,
                                    type: UtenStatusBadgeType.neutral,
                                    size: UtenStatusBadgeSize.small,
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Semantics(
                        label: l10n.aiSettingsEnabledSwitch,
                        child: Switch(
                          key: ValueKey('ai-provider-enabled-${provider.id}'),
                          value: provider.enabled,
                          onChanged: widget.busy
                              ? null
                              : widget.onEnabledChanged,
                        ),
                      ),
                      // 与全站一致: 收起时箭头朝下(点开往下展开), 展开后朝上。
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: UtenAnim.normal,
                        curve: UtenAnim.standard,
                        child: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: UtenSpacing.s12),
                _InfoLine(
                  icon: Icons.memory_rounded,
                  label: l10n.aiSettingsModel,
                  child: _Value(provider.model),
                ),
                _InfoLine(
                  icon: Icons.link_rounded,
                  label: l10n.aiSettingsBaseUrl,
                  child: _Value(provider.baseUrl, maxLines: 2),
                ),
                _InfoLine(
                  icon: Icons.key_rounded,
                  label: l10n.aiSettingsApiKey,
                  child: _KeyStatus(
                    provider: provider,
                    keyNotNeeded: keyNotNeeded,
                  ),
                ),
                _InfoLine(
                  icon: Icons.fact_check_outlined,
                  label: l10n.aiSettingsLastTest,
                  child: _LastTest(provider: provider),
                ),
                if (widget.testing || widget.testResult != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  AiConnectionTestView(
                    result: widget.testResult,
                    running: widget.testing,
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                Divider(height: 1, color: theme.colorScheme.outlineVariant),
                const SizedBox(height: UtenSpacing.s12),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    UtenButton(
                      key: ValueKey('ai-provider-test-${provider.id}'),
                      type: UtenButtonType.tonal,
                      size: UtenButtonSize.small,
                      height: aiSettingsActionHeight,
                      icon: Icons.network_check_rounded,
                      isLoading: widget.testing,
                      onPressed: widget.busy || widget.testing
                          ? null
                          : widget.onTest,
                      child: Text(
                        widget.testing
                            ? l10n.aiSettingsTesting
                            : l10n.aiSettingsTest,
                      ),
                    ),
                    UtenButton(
                      key: ValueKey('ai-provider-edit-${provider.id}'),
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      height: aiSettingsActionHeight,
                      icon: Icons.edit_outlined,
                      onPressed: widget.busy ? null : widget.onEdit,
                      child: Text(l10n.aiSettingsEdit),
                    ),
                    if (!provider.isDefault)
                      UtenButton(
                        key: ValueKey('ai-provider-default-${provider.id}'),
                        type: UtenButtonType.secondary,
                        size: UtenButtonSize.small,
                        height: aiSettingsActionHeight,
                        icon: Icons.star_outline_rounded,
                        onPressed: widget.busy ? null : widget.onSetDefault,
                        child: Text(l10n.aiSettingsSetDefault),
                      ),
                    UtenButton(
                      key: ValueKey('ai-provider-delete-${provider.id}'),
                      type: UtenButtonType.ghost,
                      size: UtenButtonSize.small,
                      height: aiSettingsActionHeight,
                      icon: Icons.delete_outline_rounded,
                      onPressed: widget.busy || !widget.canDelete
                          ? null
                          : widget.onDelete,
                      onDisabledTap: !widget.busy && !widget.canDelete
                          ? widget.onDelete
                          : null,
                      child: Text(l10n.aiSettingsDelete),
                    ),
                  ],
                ),
                if (provider.updatedAt != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    l10n.aiSettingsUpdatedBy(
                      provider.updatedByName ?? '-',
                      DisplayDateTime.beijing(provider.updatedAt),
                    ),
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
            secondChild: const SizedBox(width: double.infinity),
            crossFadeState: _expanded
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            duration: UtenAnim.normal,
            sizeCurve: UtenAnim.standard,
          ),
        ],
      ),
    );
  }
}

/// 预设首字头像: 国内青绿、境外紫、本机蓝的渐变圆; 停用时变淡。
///
/// 字色取主题的 onPrimary: 浅色主题为白字配深一档渐变, 深色主题为深字配浅一档渐变,
/// 两种主题下对比度都够。
class AiProviderAvatar extends StatelessWidget {
  const AiProviderAvatar({
    super.key,
    required this.label,
    required this.region,
    this.size = 44,
    this.dimmed = false,
  });

  final String label;
  final AiRegion region;
  final double size;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final colors = switch ((region, dark)) {
      (AiRegion.mainland, false) => const [
        UtenColors.teal400,
        UtenColors.teal700,
      ],
      (AiRegion.mainland, true) => const [
        UtenColors.teal200,
        UtenColors.teal400,
      ],
      (AiRegion.overseas, false) => const [
        UtenColors.violetOnDark,
        UtenColors.violet,
      ],
      (AiRegion.overseas, true) => const [
        UtenColors.violetBg,
        UtenColors.violetOnDark,
      ],
      (AiRegion.local, false) => const [UtenColors.infoOnDark, UtenColors.info],
      (AiRegion.local, true) => const [
        UtenColors.infoBg,
        UtenColors.infoOnDark,
      ],
    };
    return ExcludeSemantics(
      child: Opacity(
        opacity: dimmed ? 0.45 : 1,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
            borderRadius: BorderRadius.circular(size * 0.3),
          ),
          child: Text(
            aiAvatarInitial(label),
            style: TextStyle(
              color: theme.colorScheme.onPrimary,
              fontSize: size * 0.42,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.label,
    required this.child,
  });

  final IconData icon;
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 16, color: AiTone.muted(theme)),
          ),
          const SizedBox(width: UtenSpacing.s8),
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value(this.text, {this.maxLines = 1});

  final String text;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      text.isEmpty ? '-' : text,
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium,
    );
  }
}

class _KeyStatus extends StatelessWidget {
  const _KeyStatus({required this.provider, required this.keyNotNeeded});

  final AiProviderConfig provider;
  final bool keyNotNeeded;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (provider.apiKeyUnreadable) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: UtenStatusBadge(
          key: const ValueKey('ai-provider-key-unreadable'),
          label: l10n.aiSettingsKeyUnreadable,
          type: UtenStatusBadgeType.danger,
          icon: Icons.error_outline_rounded,
          size: UtenStatusBadgeSize.small,
        ),
      );
    }
    if (provider.apiKeyConfigured) {
      final tail = provider.apiKeyTail;
      // 徽章只写「已配置」, 尾号掩码放在旁边紧凑显示(与「上次测试」徽章 + 时间同一排法)。
      return Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          UtenStatusBadge(
            key: const ValueKey('ai-provider-key-configured'),
            label: l10n.aiSettingsKeyConfiguredPlain,
            type: UtenStatusBadgeType.neutral,
            icon: Icons.lock_outline_rounded,
            size: UtenStatusBadgeSize.small,
          ),
          if (tail != null)
            AiMaskedKey(
              tail,
              key: const ValueKey('ai-provider-key-mask'),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
        ],
      );
    }
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: UtenStatusBadge(
        key: const ValueKey('ai-provider-key-missing'),
        label: keyNotNeeded
            ? l10n.aiSettingsKeyNotNeeded
            : l10n.aiSettingsKeyMissing,
        type: keyNotNeeded
            ? UtenStatusBadgeType.neutral
            : UtenStatusBadgeType.warning,
        size: UtenStatusBadgeSize.small,
      ),
    );
  }
}

class _LastTest extends StatelessWidget {
  const _LastTest({required this.provider});

  final AiProviderConfig provider;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final ok = provider.lastTestOk;
    if (ok == null || provider.lastTestAt == null) {
      return _Value(l10n.aiSettingsNeverTested);
    }
    final time = DisplayDateTime.beijing(provider.lastTestAt);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 徽章只写结论, 时间放在旁边的普通文字里: 窄屏时间自动换行, 不被省略号吃掉。
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            UtenStatusBadge(
              key: const ValueKey('ai-provider-last-test-badge'),
              label: ok
                  ? l10n.aiSettingsTestPassedShort
                  : l10n.aiSettingsTestFailedShort,
              type: ok
                  ? UtenStatusBadgeType.success
                  : UtenStatusBadgeType.danger,
              icon: ok ? Icons.check_rounded : Icons.close_rounded,
              size: UtenStatusBadgeSize.small,
            ),
            Text(
              time,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        if (!ok && provider.lastTestMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              provider.lastTestMessage!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
