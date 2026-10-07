// 按人限额编辑面板(ADR-164): 停用开关(危险语义+二次确认) + 每日 token/任务数限额。
//
// - 两个限额输入留空=跟随全局默认(helper text 常驻); 填了需为 1..上限 的整数。
// - 保存带 rowVersion 乐观锁: 期间被别人改过服务端回 409, 面板留在原地提示
//   「配置有变化，请刷新后再保存」, 管理员重进面板再保存。
// - 保存要求再认证(403 REAUTH_REQUIRED → 网络层弹统一密码框后自动重发一次),
//   本面板不自己问密码; 保存期间挂遮罩防双击。
// - 开启「停用」时先弹二次确认(danger 按钮); 恢复启用不需要确认。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/ai_usage_dashboard_models.dart';
import '../repositories/ai_usage_dashboard_repository.dart';
import 'ai_usage_trend_card.dart';

/// 面板要编辑的一个人: 看板行与人员详情页都能组装。
class AiUsageLimitTarget {
  const AiUsageLimitTarget({
    required this.userId,
    required this.name,
    required this.code,
    required this.todayTokens,
    required this.disabled,
    required this.dailyTokenLimit,
    required this.dailyJobLimit,
    required this.rowVersion,
  });

  factory AiUsageLimitTarget.fromPerson(AiUsagePerson person) =>
      AiUsageLimitTarget(
        userId: person.userId,
        name: person.name,
        code: person.code,
        todayTokens: person.todayTokens,
        disabled: person.disabled,
        dailyTokenLimit: person.dailyTokenLimit,
        dailyJobLimit: person.dailyJobLimit,
        rowVersion: person.rowVersion,
      );

  factory AiUsageLimitTarget.fromDetail(AiUsagePersonDetail detail) =>
      AiUsageLimitTarget(
        userId: detail.userId,
        name: detail.name,
        code: detail.code,
        todayTokens: detail.todayTokens,
        disabled: detail.limits.disabled,
        dailyTokenLimit: detail.limits.dailyTokenLimit,
        dailyJobLimit: detail.limits.dailyJobLimit,
        rowVersion: detail.limits.rowVersion,
      );

  final String userId;
  final String name;
  final String code;
  final int todayTokens;
  final bool disabled;
  final int? dailyTokenLimit;
  final int? dailyJobLimit;

  /// 乐观锁版本; null=看板行没带(旧 wire, 编辑面板先取人员详情补齐), ≥0=已有配置行,
  /// -1=已知无配置行(首建)。
  final int? rowVersion;

  String get display => code.isEmpty ? name : '$name（$code）';
}

/// 编辑 [target] 的限额与停用; 关闭后返回是否保存过。
Future<bool> showAiUsageLimitEditor(
  BuildContext context, {
  required AiUsageLimitTarget target,
}) async {
  final saved = await showUtenAdaptivePanel<bool>(
    context: context,
    drawerWidth: 480,
    // 正在改的限额不该被误点空白处丢掉; 关闭走右上角按钮。
    barrierDismissible: false,
    enableDrag: false,
    builder: (_) => AiUsageLimitEditor(target: target),
  );
  return saved == true;
}

class AiUsageLimitEditor extends ConsumerStatefulWidget {
  const AiUsageLimitEditor({super.key, required this.target});

  final AiUsageLimitTarget target;

  @override
  ConsumerState<AiUsageLimitEditor> createState() => _AiUsageLimitEditorState();
}

class _AiUsageLimitEditorState extends ConsumerState<AiUsageLimitEditor> {
  static const maxTokenLimit = 1000000000000; // 10^12, 与服务端校验一致
  static const maxJobLimit = 10000;

  late final TextEditingController _tokens;
  late final TextEditingController _jobs;

  /// 已就绪的编辑对象; 看板行没带 rowVersion 时先取人员详情, 取到前为 null。
  AiUsageLimitTarget? _target;
  bool _resolving = false;
  String? _resolveError;
  bool _disabled = false;
  bool _submitted = false;
  bool _saving = false;
  bool _closing = false;
  String? _message;

  AiUsageDashboardRepository get _repository =>
      ref.read(aiUsageDashboardRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _tokens = TextEditingController();
    _jobs = TextEditingController();
    final target = widget.target;
    // 服务端现在随看板行下发 rowVersion(COALESCE(row_version,-1)): 已知版本(≥0,
    // 含 -1 之外的所有现值)直接编辑, 不再先 GET 人员详情补齐; null(旧 wire 未知)才补。
    if (target.rowVersion != null && target.rowVersion! >= 0) {
      _applyTarget(target);
    } else {
      _resolve();
    }
  }

  @override
  void dispose() {
    _tokens.dispose();
    _jobs.dispose();
    super.dispose();
  }

  /// 补齐乐观锁版本: 旧 wire 的看板行没带 rowVersion 时先读一次人员详情(拿 limits 现值)。
  /// 现在服务端始终下发 rowVersion, 这里只剩未知回退路径。
  Future<void> _resolve() async {
    if (_resolving) return;
    setState(() {
      _resolving = true;
      _resolveError = null;
    });
    try {
      final detail = await _repository.person(
        widget.target.userId,
        AiUsageWindow.day,
      );
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _applyTarget(AiUsageLimitTarget.fromDetail(detail));
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveError = error.message.isNotEmpty
            ? error.message
            : AppLocalizations.of(context).aiUsageLoadFailed;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _resolveError = AppLocalizations.of(context).aiUsageLoadFailed;
      });
    }
  }

  void _applyTarget(AiUsageLimitTarget target) {
    _target = target;
    _disabled = target.disabled;
    _tokens.text = target.dailyTokenLimit?.toString() ?? '';
    _jobs.text = target.dailyJobLimit?.toString() ?? '';
  }

  String? _limitError(String? value, int max, AppLocalizations l10n) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null; // 留空=跟随全局默认
    final parsed = int.tryParse(text);
    if (parsed == null || parsed < 1 || parsed > max) {
      return l10n.aiUsageLimitRangeError(max);
    }
    return null;
  }

  int? _parseLimit(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : int.tryParse(trimmed);
  }

  Future<void> _save() async {
    final target = _target;
    if (target == null || _saving || _closing) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _submitted = true);
    if (_limitError(_tokens.text, maxTokenLimit, l10n) != null ||
        _limitError(_jobs.text, maxJobLimit, l10n) != null) {
      setState(() => _message = null);
      return;
    }
    // 从启用切到停用是危险操作: 先二次确认; 恢复启用不需要。
    if (_disabled && !target.disabled) {
      final confirmed = await UtenDialog.show(
        context,
        title: l10n.aiUsageDisableLabel,
        content: Text(l10n.aiUsageDisableConfirm),
        confirmLabel: l10n.aiUsageDisableAction,
        cancelLabel: l10n.aiSettingsCancel,
        danger: true,
      );
      if (confirmed != true || !mounted || _saving) return;
    }
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      await _repository.saveLimits(
        target.userId,
        disabled: _disabled,
        dailyTokenLimit: _parseLimit(_tokens.text),
        dailyJobLimit: _parseLimit(_jobs.text),
        rowVersion: target.rowVersion ?? -1,
      );
      if (!mounted) return;
      context.appSuccess(l10n.aiSettingsSaved);
      _closing = true;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        // 409=乐观锁冲突: 配置已被别人改过, 提示刷新后再保存。
        _message = _isConflict(error)
            ? l10n.aiUsageConflict
            : (error.message.isNotEmpty
                  ? error.message
                  : l10n.aiSettingsSaveFailed);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _message = l10n.aiSettingsSaveFailed;
      });
    }
  }

  static bool _isConflict(ApiException error) =>
      error.httpStatus == 409 || error.code == 'CONFLICT';

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final target = _target;
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          _Header(
            title: l10n.aiUsageSetLimits,
            subtitle: widget.target.display,
            onClose: _close,
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: target == null
                ? _resolveBody(l10n)
                : Stack(
                    children: [
                      Positioned.fill(child: _form(l10n, theme, target)),
                      if (_saving)
                        UtenBusyOverlay(
                          semanticsKey: const ValueKey('ai-usage-limit-busy'),
                          title: l10n.aiSettingsBusySaving,
                        ),
                    ],
                  ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          if (target != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Row(
                  children: [
                    Expanded(
                      child: UtenButton(
                        key: const ValueKey('ai-usage-limit-cancel'),
                        type: UtenButtonType.secondary,
                        height: 48,
                        onPressed: _saving ? null : _close,
                        child: Text(l10n.aiSettingsCancel),
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: UtenButton(
                        key: const ValueKey('ai-usage-limit-save'),
                        height: 48,
                        icon: Icons.save_outlined,
                        isLoading: _saving,
                        onPressed: _save,
                        child: Text(l10n.aiSettingsSave),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _resolveBody(AppLocalizations l10n) {
    if (_resolving) {
      return const Center(child: LinearProgressIndicator(minHeight: 2));
    }
    return UtenEmpty.error(
      key: const ValueKey('ai-usage-limit-load-error'),
      message: _resolveError ?? l10n.aiUsageLoadFailed,
      actionLabel: l10n.aiSettingsRetry,
      onAction: _resolve,
    );
  }

  Widget _form(
    AppLocalizations l10n,
    ThemeData theme,
    AiUsageLimitTarget target,
  ) {
    return Form(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s20,
          UtenSpacing.s16,
          UtenSpacing.s20,
          UtenSpacing.s24,
        ),
        children: [
          Text(
            l10n.aiUsageTodayUsed(formatAiUsageNumber(target.todayTokens)),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _disableTile(l10n, theme),
          const SizedBox(height: UtenSpacing.s16),
          UtenInput(
            key: const ValueKey('ai-usage-limit-tokens'),
            label: l10n.aiUsageLimitTokensLabel,
            controller: _tokens,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            errorMessage: _submitted
                ? _limitError(_tokens.text, maxTokenLimit, l10n)
                : null,
            onChanged: (_) {
              if (_message != null) setState(() => _message = null);
            },
          ),
          _HelperText(text: l10n.aiUsageLimitHint),
          const SizedBox(height: UtenSpacing.s12),
          UtenInput(
            key: const ValueKey('ai-usage-limit-jobs'),
            label: l10n.aiUsageLimitJobsLabel,
            controller: _jobs,
            enabled: !_saving,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            errorMessage: _submitted
                ? _limitError(_jobs.text, maxJobLimit, l10n)
                : null,
            onChanged: (_) {
              if (_message != null) setState(() => _message = null);
            },
          ),
          _HelperText(text: l10n.aiUsageLimitHint),
          if (_message != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            UtenInlineNotice(
              key: const ValueKey('ai-usage-limit-error'),
              level: UtenInlineNoticeLevel.error,
              message: _message!,
            ),
          ],
        ],
      ),
    );
  }

  /// 危险开关: 开启时描边与标题转红, 与「数据出境确认」同款强调方式。
  Widget _disableTile(AppLocalizations l10n, ThemeData theme) => DecoratedBox(
    decoration: BoxDecoration(
      borderRadius: UtenRadius.controlAll,
      border: Border.all(
        color: _disabled
            ? theme.colorScheme.error
            : theme.colorScheme.outlineVariant,
      ),
    ),
    child: SwitchListTile(
      key: const ValueKey('ai-usage-limit-disabled'),
      value: _disabled,
      onChanged: _saving
          ? null
          : (value) => setState(() {
              _disabled = value;
              _message = null;
            }),
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.controlAll),
      contentPadding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
      title: Text(
        l10n.aiUsageDisableLabel,
        style: theme.textTheme.bodyLarge?.copyWith(
          color: _disabled ? theme.colorScheme.error : null,
          fontWeight: _disabled ? FontWeight.w700 : null,
        ),
      ),
      subtitle: Text(
        l10n.aiUsageDisableHint,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ),
  );
}

/// helper text 常驻(不只在出错时出现): 说明「留空=跟随全局默认」。
class _HelperText extends StatelessWidget {
  const _HelperText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s6, left: UtenSpacing.s4),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle, this.onClose});

  final String title;
  final String subtitle;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Icon(Icons.tune_rounded, size: 28, color: theme.colorScheme.primary),
          const SizedBox(width: UtenSpacing.s12),
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
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey('ai-usage-limit-close'),
            tooltip: l10n.aiSettingsClose,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose ?? () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }
}
