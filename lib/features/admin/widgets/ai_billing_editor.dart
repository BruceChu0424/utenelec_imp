// AI 服务计费方式与套餐额度编辑面板(自 AiUsageAuditPanel._BillingForm 迁移, 逻辑不变)。
//
// - 计费方式: 未设置 / 按量计费(币种 + 每百万输入/输出单价) / 套餐; 按量才参与估算费用。
// - 保存带乐观锁 version: 期间被别人改过服务端回 409, 面板留在原地提示。
// - 读/写被拒(401/403)时服务端会话已换人: 面板自行关闭并回调 onDenied, 由宿主清数据。
// - 面板不重复问密码: 保存要求再认证时网络层弹统一密码框后自动重发一次。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/ai_provider_models.dart';
import '../repositories/ai_usage_audit_repository.dart';

/// 打开计费设置面板; 返回 true=本次会话里至少保存成功过一次(宿主据此刷新)。
Future<bool> showAiBillingEditor(
  BuildContext context, {
  required List<AiProviderConfig> providers,
  String? initialProviderId,
  void Function(ApiException error)? onDenied,
}) async {
  final saved = await showUtenAdaptivePanel<bool>(
    context: context,
    drawerWidth: 480,
    // 正在编辑的计费设置不该被误点空白处丢掉; 关闭走右上角按钮。
    barrierDismissible: false,
    enableDrag: false,
    builder: (_) => AiBillingEditor(
      providers: providers,
      initialProviderId: initialProviderId,
      onDenied: onDenied,
    ),
  );
  return saved == true;
}

class AiBillingEditor extends ConsumerStatefulWidget {
  const AiBillingEditor({
    super.key,
    required this.providers,
    this.initialProviderId,
    this.onDenied,
  });

  final List<AiProviderConfig> providers;
  final String? initialProviderId;
  final void Function(ApiException error)? onDenied;

  @override
  ConsumerState<AiBillingEditor> createState() => _AiBillingEditorState();
}

class _AiBillingEditorState extends ConsumerState<AiBillingEditor> {
  /// 会话/服务器/权限任一变化即失效: 在途回调不得再读写(与页面门禁同款栅栏)。
  late final Object _owner;
  bool get _active => mounted && _owner == _billingOwner(ref);

  String? _providerId;
  Map<String, dynamic>? _value;
  String _mode = 'UNKNOWN', _currency = 'CNY';
  String? _message;
  bool _messageIsSuccess = false;
  bool _busy = false;
  bool _saved = false;
  final _input = TextEditingController(), _output = TextEditingController();
  final _quota5h = TextEditingController(),
      _quotaWeekly = TextEditingController();

  AiUsageAuditRepository get _repository =>
      ref.read(aiUsageAuditRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = _billingOwner(ref);
    _providerId =
        widget.initialProviderId ??
        (widget.providers.length == 1 ? widget.providers.first.id : null);
    if (_providerId != null) _load();
  }

  @override
  void dispose() {
    _input.dispose();
    _output.dispose();
    _quota5h.dispose();
    _quotaWeekly.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_active || _providerId == null || _busy) return;
    setState(() {
      _busy = true;
      _message = null;
      _messageIsSuccess = false;
      _value = null;
    });
    try {
      final value = await _repository.billing(_providerId!);
      if (!_active) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      setState(() {
        _value = value;
        _mode = _text(value['billingMode'], fallback: 'UNKNOWN');
        _currency = _text(value['currency'], fallback: 'CNY');
        _busy = false;
        _input.text = _text(value['inputPerMillion']);
        _output.text = _text(value['outputPerMillion']);
        _quota5h.text = _text(value['quota5h']);
        _quotaWeekly.text = _text(value['quotaWeekly']);
      });
    } catch (error) {
      if (!mounted) return;
      if (_isAccessDenied(error)) {
        widget.onDenied?.call(error as ApiException);
        _close();
        return;
      }
      setState(() {
        _busy = false;
        _messageIsSuccess = false;
        _message = error is ApiException
            ? error.message
            : AppLocalizations.of(context).aiAuditBillingLoadFailed;
      });
    }
  }

  Future<void> _save() async {
    if (!_active || _value == null || _busy) return;
    final l10n = AppLocalizations.of(context);
    if (_mode == 'METERED' &&
        (!_validPrice(_input.text.trim()) ||
            !_validPrice(_output.text.trim()))) {
      setState(() {
        _messageIsSuccess = false;
        _message = l10n.aiAuditPriceInvalid;
      });
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _messageIsSuccess = false;
    });
    try {
      final value = await _repository.saveBilling(_providerId!, {
        'version': _value!['version'],
        'billingMode': _mode,
        'currency': _mode == 'METERED' ? _currency : null,
        'inputPerMillion': _mode == 'METERED' ? _input.text.trim() : null,
        'outputPerMillion': _mode == 'METERED' ? _output.text.trim() : null,
        'quota5h': _mode == 'SUBSCRIPTION' ? _intOrNull(_quota5h.text) : null,
        'quotaWeekly': _mode == 'SUBSCRIPTION'
            ? _intOrNull(_quotaWeekly.text)
            : null,
      });
      if (!_active) {
        // 会话已换人: 不能再碰状态, 但也别把抽屉卡在转圈。
        if (mounted) setState(() => _busy = false);
        return;
      }
      setState(() {
        _value = value;
        _busy = false;
        _saved = true;
        _messageIsSuccess = true;
        _message = l10n.aiAuditBillingSaved;
      });
    } catch (error) {
      if (!mounted) return;
      if (_isAccessDenied(error)) {
        widget.onDenied?.call(error as ApiException);
        _close();
        return;
      }
      if (!_active) {
        if (mounted) setState(() => _busy = false);
        return;
      }
      setState(() {
        _busy = false;
        _messageIsSuccess = false;
        _message = error is ApiException
            ? error.message
            : l10n.aiAuditSaveFailed;
      });
    }
  }

  void _close() {
    if (!mounted) return;
    Navigator.of(context).pop(_saved);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.receipt_long_outlined,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    l10n.aiAuditBillingTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: _busy ? null : _close,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (_busy) const LinearProgressIndicator(minHeight: 2),
            UtenDropdownField(
              key: const ValueKey('ai-billing-provider'),
              label: l10n.aiAuditSelectProvider,
              value: _providerId,
              allowClear: false,
              items: [
                for (final provider in widget.providers)
                  UtenDropdownItem(value: provider.id, label: provider.name),
              ],
              enabled: !_busy,
              onChanged: (value) {
                if (value == null || value == _providerId) return;
                setState(() => _providerId = value);
                _load();
              },
            ),
            if (_providerId != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _value == null
                          ? l10n.aiAuditBillingMode
                          : l10n.aiAuditModel(_text(_value!['model'])),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.aiAuditReloadBilling,
                    onPressed: _busy ? null : _load,
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                ],
              ),
            ],
            if (_value != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              UtenDropdownField(
                label: l10n.aiAuditBillingMode,
                value: _mode,
                allowClear: false,
                items: [
                  UtenDropdownItem(
                    value: 'UNKNOWN',
                    label: l10n.aiAuditUnknownBilling,
                  ),
                  UtenDropdownItem(
                    value: 'METERED',
                    label: l10n.aiAuditMetered,
                  ),
                  UtenDropdownItem(
                    value: 'SUBSCRIPTION',
                    label: l10n.aiAuditSubscription,
                  ),
                ],
                enabled: !_busy,
                onChanged: (value) =>
                    setState(() => _mode = value ?? 'UNKNOWN'),
              ),
              if (_mode == 'METERED') ...[
                const SizedBox(height: UtenSpacing.s12),
                UtenDropdownField(
                  label: l10n.aiAuditCurrency,
                  value: _currency,
                  allowClear: false,
                  items: [
                    UtenDropdownItem(value: 'CNY', label: l10n.aiAuditCny),
                    UtenDropdownItem(value: 'USD', label: l10n.aiAuditUsd),
                    UtenDropdownItem(value: 'EUR', label: l10n.aiAuditEur),
                    UtenDropdownItem(value: 'HKD', label: l10n.aiAuditHkd),
                    UtenDropdownItem(value: 'JPY', label: l10n.aiAuditJpy),
                    UtenDropdownItem(value: 'KRW', label: l10n.aiAuditKrw),
                    if (!const {
                      'CNY',
                      'USD',
                      'EUR',
                      'HKD',
                      'JPY',
                      'KRW',
                    }.contains(_currency))
                      UtenDropdownItem(value: _currency, label: _currency),
                  ],
                  enabled: !_busy,
                  onChanged: (value) =>
                      setState(() => _currency = value ?? 'CNY'),
                ),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  controller: _input,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  label: l10n.aiAuditInputPrice,
                ),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  controller: _output,
                  enabled: !_busy,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  label: l10n.aiAuditOutputPrice,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  l10n.aiAuditPriceHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (_mode == 'SUBSCRIPTION') ...[
                const SizedBox(height: UtenSpacing.s12),
                // 已用按平台成功调用自动统计(5 小时/每周滚动窗口), 额度填好即得剩余。
                _QuotaUsage(quota: _value!['quota']),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  controller: _quota5h,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  label: l10n.aiAuditFiveHourQuota,
                ),
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  controller: _quotaWeekly,
                  enabled: !_busy,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  label: l10n.aiAuditWeeklyQuota,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  l10n.aiAuditQuotaHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s8),
                child: Text(
                  _message!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _messageIsSuccess
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ),
            if (_value != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  key: const ValueKey('ai-billing-save'),
                  onPressed: _busy ? null : _save,
                  child: Text(l10n.aiAuditSaveBilling),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};

int? _intOrNull(String raw) {
  final trimmed = raw.trim();
  return trimmed.isEmpty ? null : int.tryParse(trimmed);
}

/// 套餐已用条: 近5小时/本周两行, 额度已配置时附进度条(≥80% 转黄, ≥100% 转红)。
class _QuotaUsage extends StatelessWidget {
  const _QuotaUsage({required this.quota});

  final Object? quota;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    (int, int?) window(String key) {
      final map = quota is Map ? _map(quota) : const <String, dynamic>{};
      final windows = map['windows'];
      if (windows is! List) return (0, null);
      for (final row in windows) {
        if (row is Map && row['key'] == key) {
          final used = row['used'];
          final quotaValue = row['quota'];
          return (
            used is num ? used.toInt() : 0,
            quotaValue == null
                ? null
                : quotaValue is num
                ? quotaValue.toInt()
                : int.tryParse('$quotaValue'),
          );
        }
      }
      return (0, null);
    }

    Widget meter(String text, int? quotaValue, int used) {
      final dark = theme.brightness == Brightness.dark;
      final ratio = quotaValue == null || quotaValue <= 0
          ? null
          : used / quotaValue;
      final color = ratio == null
          ? theme.colorScheme.primary
          : ratio >= 1
          ? (dark ? UtenColors.errorOnDark : UtenColors.errorText)
          : ratio >= 0.8
          ? (dark ? UtenColors.warningOnDark : UtenColors.warningText)
          : theme.colorScheme.primary;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (ratio != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 6,
                value: ratio.clamp(0.0, 1.0),
                color: color,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ],
        ],
      );
    }

    final (used5h, quota5h) = window('FIVE_HOURS');
    final (usedWeek, quotaWeek) = window('WEEKLY');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        meter(
          l10n.aiAuditQuota5hUsed(used5h, quota5h?.toString() ?? '—'),
          quota5h,
          used5h,
        ),
        const SizedBox(height: UtenSpacing.s8),
        meter(
          l10n.aiAuditQuotaWeeklyUsed(usedWeek, quotaWeek?.toString() ?? '—'),
          quotaWeek,
          usedWeek,
        ),
      ],
    );
  }
}

String _text(Object? value, {String fallback = ''}) =>
    value == null || value.toString().isEmpty ? fallback : value.toString();

bool _validPrice(String text) {
  if (!RegExp(r'^[0-9]{1,8}(?:\.[0-9]{1,10})?$').hasMatch(text)) return false;
  final parts = text.split('.');
  final whole = BigInt.parse(parts.first);
  final maximum = BigInt.from(1000000);
  return whole < maximum ||
      (whole == maximum &&
          (parts.length == 1 || !RegExp('[1-9]').hasMatch(parts.last)));
}

bool _isAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        error.code == 'FORBIDDEN' ||
        error.code == 'UNAUTHENTICATED');

Object _billingOwner(WidgetRef ref) => (
  ref.read(authenticatedScopeProvider),
  confirmedSessionSnapshot(ref.read(sessionSnapshotProvider))?.generation,
  ref.read(apiBaseUrlProvider),
  ref.read(sessionProvider).user?.superAdmin,
  ref.read(currentPermissionsProvider).contains(Perm.authorizationManage),
);
