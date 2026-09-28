// AdminAiSettingsPage - AI 服务设置(ADR-133; 页面文档 docs/03-页面/AI服务设置页.md)
//
// 超级管理员配置公共 AI 平台用哪家大模型服务: 服务商预设、接口地址、模型、密钥、连接测试、
// 设为默认、启停、近 30 天用量。任何功能(目前是销售客户文件识别)都经服务端公共网关
// 调用这里的「默认服务」, 换服务商不用改代码。
//
// 安全:
//   * 路由 /admin/* 要求 authorization:manage; 服务端 Controller 另校验 superAdmin;
//   * 密钥只写不读: 页面只拿到掩码(••••abcd), 输入框不接自动填充、不进草稿(本页不是草稿页);
//   * 增删改/设默认/启停/用已存密钥测试 → 服务端要求再认证, 网络层弹统一密码框,
//     本页的遮罩只挂在纯网络段且会给密码框让位;
//   * 服务器没开放境外服务商时不能选; 开放了也要逐个勾选数据出境确认。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../models/ai_provider_models.dart';
import '../repositories/ai_provider_repository.dart';
import '../widgets/ai_provider_card.dart';
import '../widgets/ai_provider_editor.dart';
import '../widgets/ai_settings_labels.dart';
import '../widgets/ai_usage_card.dart';

class AdminAiSettingsPage extends ConsumerStatefulWidget {
  const AdminAiSettingsPage({super.key});

  @override
  ConsumerState<AdminAiSettingsPage> createState() =>
      _AdminAiSettingsPageState();
}

class _AdminAiSettingsPageState extends ConsumerState<AdminAiSettingsPage> {
  List<AiProviderConfig>? _providers;
  AiPresetCatalog _catalog = AiPresetCatalog.empty;
  AiUsageSummary? _usage;
  bool _usageFailed = false;
  bool _loading = false;
  String? _error;
  bool _noAccess = false;

  /// 遮罩标题; 非空即挂 UtenBusyOverlay(只包纯网络段)。
  String? _busy;
  final Set<String> _testing = {};
  final Map<String, AiConnectionTestResult> _testResults = {};
  int _loadSeq = 0;

  AiProviderRepository get _repository =>
      ref.read(aiProviderRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool quiet = false}) async {
    final seq = ++_loadSeq;
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final results = await Future.wait<Object>([
        _repository.list(),
        _repository.presets(),
      ]);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _providers = results[0] as List<AiProviderConfig>;
        _catalog = results[1] as AiPresetCatalog;
        _loading = false;
        _error = null;
        _noAccess = false;
      });
      await _loadUsage(seq);
    } on ApiException catch (error) {
      if (!mounted || seq != _loadSeq) return;
      _onLoadFailed(
        error.message,
        noAccess: error.httpStatus == 403 || error.code == 'FORBIDDEN',
      );
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
      _onLoadFailed(AppLocalizations.of(context).aiSettingsLoadFailed);
    }
  }

  void _onLoadFailed(String message, {bool noAccess = false}) {
    if (_providers != null) {
      // 已有数据时刷新失败: 保留旧数据, 只提示。
      setState(() => _loading = false);
      context.appError(message);
      return;
    }
    setState(() {
      _loading = false;
      _error = message;
      _noAccess = noAccess;
    });
  }

  Future<void> _loadUsage(int seq) async {
    try {
      final usage = await _repository.usage();
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _usage = usage;
        _usageFailed = false;
      });
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
      setState(() => _usageFailed = true);
    }
  }

  Future<void> _refresh() async {
    if (_loading || _busy != null) return;
    await _load(quiet: _providers != null);
  }

  Future<void> _openEditor({AiProviderConfig? existing}) async {
    if (_busy != null) return;
    await showAiProviderEditor(context, catalog: _catalog, existing: existing);
    if (!mounted) return;
    // 保存或「用已存密钥测试」都会改变列表(测试结果也记在配置上)。
    await _load(quiet: true);
  }

  Future<void> _testStored(AiProviderConfig provider) async {
    final l10n = AppLocalizations.of(context);
    final preset = _catalog.byCode(provider.preset);
    if (provider.apiKeyUnreadable) {
      context.appWarning(l10n.aiSettingsKeyUnreadable);
      return;
    }
    if (!provider.apiKeyConfigured && provider.keyRequiredWith(preset)) {
      context.appWarning(l10n.aiSettingsTestNeedsKeyEdit);
      return;
    }
    if (_testing.contains(provider.id)) return;
    setState(() {
      _testing.add(provider.id);
      _testResults.remove(provider.id);
    });
    try {
      final result = await _repository.testStored(provider.id);
      if (!mounted) return;
      setState(() => _testResults[provider.id] = result);
      await _load(quiet: true);
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.aiSettingsTestFailed);
    } finally {
      if (mounted) setState(() => _testing.remove(provider.id));
    }
  }

  /// 纯网络写操作: 期间挂遮罩(服务端要求再认证时遮罩自动让位给密码框), 结束即撤, 再静默刷新。
  Future<void> _runBusy(
    String title,
    Future<void> Function() body, {
    required String success,
  }) async {
    if (_busy != null) return;
    setState(() => _busy = title);
    var ok = false;
    try {
      await body();
      ok = true;
    } on ApiException catch (error) {
      if (mounted) context.appApiError(error);
    } catch (_) {
      if (mounted) {
        context.appError(AppLocalizations.of(context).aiSettingsSaveFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    if (!ok || !mounted) return;
    context.appSuccess(success);
    await _load(quiet: true);
  }

  Future<void> _setDefault(AiProviderConfig provider) {
    final l10n = AppLocalizations.of(context);
    return _runBusy(
      l10n.aiSettingsBusySaving,
      () => _repository.setDefault(provider.id),
      success: l10n.aiSettingsDefaultSet(provider.name),
    );
  }

  Future<void> _setEnabled(AiProviderConfig provider, bool enabled) {
    final l10n = AppLocalizations.of(context);
    return _runBusy(
      l10n.aiSettingsBusySaving,
      () => _repository.setEnabled(provider.id, enabled: enabled),
      success: enabled
          ? l10n.aiSettingsEnabledOn(provider.name)
          : l10n.aiSettingsEnabledOff(provider.name),
    );
  }

  Future<void> _delete(AiProviderConfig provider) async {
    final l10n = AppLocalizations.of(context);
    if (!_canDelete(provider)) {
      context.appWarning(l10n.aiSettingsDeleteDefaultBlocked);
      return;
    }
    final confirmed = await UtenDialog.show(
      context,
      title: l10n.aiSettingsDeleteTitle,
      content: Text(l10n.aiSettingsDeleteMessage(provider.name)),
      confirmLabel: l10n.aiSettingsDelete,
      cancelLabel: l10n.aiSettingsCancel,
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    await _runBusy(
      l10n.aiSettingsBusyDeleting,
      () => _repository.delete(provider.id),
      success: l10n.aiSettingsDeleted,
    );
  }

  /// 默认服务只有在它是最后一个时才能删除(与服务端规则一致)。
  bool _canDelete(AiProviderConfig provider) =>
      !provider.isDefault || (_providers?.length ?? 0) <= 1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final providers = _providers;
    final Widget body;
    if (_loading && providers == null) {
      body = const _LoadingSkeleton();
    } else if (_error != null && providers == null) {
      body = UtenEmpty.error(
        key: const ValueKey('ai-settings-error'),
        message: _noAccess ? l10n.aiSettingsNoAccess : _error!,
        actionLabel: _noAccess ? null : l10n.aiSettingsRetry,
        onAction: _noAccess ? null : _load,
      );
    } else {
      body = RefreshIndicator(onRefresh: _refresh, child: _content(l10n));
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.aiSettingsTitle,
        leading: const UtenBackButton(),
        actions: [
          IconButton(
            key: const ValueKey('ai-settings-refresh'),
            tooltip: l10n.aiSettingsRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading || _busy != null ? null : _refresh,
          ),
        ],
      ),
      body: UtenContentContainer(
        child: Stack(
          children: [
            Positioned.fill(child: body),
            if (_busy != null)
              UtenBusyOverlay(
                semanticsKey: const ValueKey('ai-settings-busy'),
                title: _busy!,
              ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: providers == null
          ? null
          : UtenFloatingActionGroup(
              children: [
                UtenButton(
                  key: const ValueKey('ai-settings-add'),
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.large,
                  icon: Icons.add_rounded,
                  onPressed: _busy == null ? () => _openEditor() : null,
                  child: Text(l10n.aiSettingsAdd),
                ),
              ],
            ),
    );
  }

  Widget _content(AppLocalizations l10n) {
    final providers = _providers ?? const <AiProviderConfig>[];
    AiProviderConfig? defaultProvider;
    for (final provider in providers) {
      if (provider.isDefault) defaultProvider = provider;
    }
    return ListView(
      key: const ValueKey('ai-settings-list'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      children: [
        _StatusHero(
          provider: defaultProvider,
          preset: _catalog.byCode(defaultProvider?.preset),
        ),
        if (!_catalog.outboundEnabled) ...[
          const SizedBox(height: UtenSpacing.s12),
          UtenInlineNotice(
            key: const ValueKey('ai-settings-outbound-off'),
            level: UtenInlineNoticeLevel.warning,
            message: l10n.aiSettingsOutboundOff,
          ),
        ],
        const SizedBox(height: UtenSpacing.s20),
        UtenSectionHeader(
          title: l10n.aiSettingsProvidersSection,
          icon: Icons.hub_outlined,
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (providers.isEmpty)
          _EmptyProviders(onAdd: _busy == null ? () => _openEditor() : null)
        else
          UtenResponsiveGrid(
            itemCount: providers.length,
            spacing: UtenSpacing.s12,
            columns: const UtenResponsiveColumns(medium: 1, expanded: 2),
            itemBuilder: (context, index, _) {
              final provider = providers[index];
              return AiProviderCard(
                provider: provider,
                preset: _catalog.byCode(provider.preset),
                presetLabel: aiPresetLabel(
                  _catalog,
                  provider.preset,
                  fallback: provider.presetLabel,
                ),
                busy: _busy != null,
                testing: _testing.contains(provider.id),
                testResult: _testResults[provider.id],
                canDelete: _canDelete(provider),
                onTest: () => _testStored(provider),
                onEdit: () => _openEditor(existing: provider),
                onSetDefault: () => _setDefault(provider),
                onDelete: () => _delete(provider),
                onEnabledChanged: (enabled) => _setEnabled(provider, enabled),
              );
            },
          ),
        const SizedBox(height: UtenSpacing.s20),
        AiUsageCard(
          usage: _usage,
          providers: providers,
          unavailable: _usageFailed,
        ),
        const SizedBox(height: UtenSpacing.s16),
        _SecurityNote(text: l10n.aiSettingsSecurityNote),
        const SizedBox(height: UtenFloatingActionGroup.scrollClearance),
      ],
    );
  }
}

/// 顶部状态: 当前默认服务 · 模型 · 上次测试; 没有时给一句「接下来做什么」。
class _StatusHero extends StatelessWidget {
  const _StatusHero({required this.provider, required this.preset});

  final AiProviderConfig? provider;
  final AiProviderPreset? preset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final provider = this.provider;
    final usable = provider != null && provider.usableWith(preset);
    final String title;
    final String subtitle;
    if (provider == null) {
      title = l10n.aiSettingsHeroNone;
      subtitle = l10n.aiSettingsHeroNoneHint;
    } else if (!provider.enabled) {
      title = l10n.aiSettingsHeroActive(provider.name, provider.model);
      subtitle = l10n.aiSettingsHeroDefaultDisabled;
    } else if (!usable) {
      title = l10n.aiSettingsHeroActive(provider.name, provider.model);
      subtitle = provider.apiKeyUnreadable
          ? l10n.aiSettingsKeyUnreadable
          : l10n.aiSettingsHeroNeedsKey;
    } else {
      title = l10n.aiSettingsHeroActive(provider.name, provider.model);
      subtitle = l10n.aiSettingsHeroReady;
    }
    final lastTestOk = provider?.lastTestOk;
    return Container(
      key: const ValueKey('ai-settings-hero'),
      padding: const EdgeInsets.all(UtenSpacing.s20),
      decoration: BoxDecoration(
        borderRadius: UtenRadius.xlAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.primaryContainer.withValues(alpha: 0.55),
            theme.colorScheme.surface,
          ],
        ),
      ),
      child: Row(
        children: [
          const AiSparkleBadge(size: 56, animate: false),
          const SizedBox(width: UtenSpacing.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (provider != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Wrap(
                    spacing: UtenSpacing.s6,
                    runSpacing: UtenSpacing.s4,
                    children: [
                      UtenStatusBadge(
                        label: provider.region.label(l10n),
                        type: provider.region.badgeType,
                        size: UtenStatusBadgeSize.small,
                      ),
                      if (lastTestOk == null || provider.lastTestAt == null)
                        UtenStatusBadge(
                          label: l10n.aiSettingsNeverTested,
                          type: UtenStatusBadgeType.neutral,
                          size: UtenStatusBadgeSize.small,
                        )
                      else
                        UtenStatusBadge(
                          label: lastTestOk
                              ? l10n.aiSettingsLastTestOk(
                                  DisplayDateTime.beijing(provider.lastTestAt),
                                )
                              : l10n.aiSettingsLastTestFailed(
                                  DisplayDateTime.beijing(provider.lastTestAt),
                                ),
                          type: lastTestOk
                              ? UtenStatusBadgeType.success
                              : UtenStatusBadgeType.danger,
                          icon: lastTestOk
                              ? Icons.check_rounded
                              : Icons.close_rounded,
                          size: UtenStatusBadgeSize.small,
                        ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyProviders extends StatelessWidget {
  const _EmptyProviders({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return UtenCard(
      key: const ValueKey('ai-settings-empty'),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s24,
        vertical: UtenSpacing.s32,
      ),
      child: Column(
        children: [
          const AiSparkleBadge(size: 64, animate: false),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            l10n.aiSettingsEmptyTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            l10n.aiSettingsEmptyHint,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s20),
          UtenButton(
            key: const ValueKey('ai-settings-empty-add'),
            size: UtenButtonSize.large,
            icon: Icons.add_rounded,
            onPressed: onAdd,
            child: Text(l10n.aiSettingsAdd),
          ),
        ],
      ),
    );
  }
}

class _SecurityNote extends StatelessWidget {
  const _SecurityNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.shield_outlined,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 首次加载的骨架: 顶部状态条 + 两张服务卡片的轮廓。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('ai-settings-skeleton'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      physics: const NeverScrollableScrollPhysics(),
      children: [
        const UtenSkeleton(height: 104, borderRadius: UtenRadius.xl),
        const SizedBox(height: UtenSpacing.s24),
        const UtenSkeleton(width: 120, height: 18),
        const SizedBox(height: UtenSpacing.s12),
        for (var i = 0; i < 2; i++) ...[
          const UtenCard(
            child: Column(
              children: [
                Row(
                  children: [
                    UtenSkeleton(width: 44, height: 44, borderRadius: 13),
                    SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          UtenSkeleton(width: 160),
                          SizedBox(height: UtenSpacing.s8),
                          UtenSkeleton(width: 100, height: 12),
                        ],
                      ),
                    ),
                  ],
                ),
                SizedBox(height: UtenSpacing.s16),
                UtenSkeleton(height: 12),
                SizedBox(height: UtenSpacing.s8),
                UtenSkeleton(height: 12),
                SizedBox(height: UtenSpacing.s8),
                UtenSkeleton(width: 200, height: 12),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
      ],
    );
  }
}
