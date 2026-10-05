// 修改证件信息弹窗：员工详情页、HR 任务中心「证件核对」共用。
//
// 证件信息只有这一个修改入口(POST /org/employees/{id}/change-identity，employee:pii:edit)：
// 可以同时改证件类型和号码，老库把护照、港澳证件错标成身份证的也能改过来。
// - 身份证边输边校验，直接说出具体哪里不对(与后端同一句话)，不合法不发请求；
// - 只预填服务端给的明文号码(有 employee:pii:view、超管或本人才是明文)，绝不预填 **** 脱敏值；
// - 服务端拒绝时原话显示在弹窗里，弹窗不关；
// - 成功后先清忙标志再关弹窗(忙碌遮罩是 root Overlay 裸图层，见
//   uten_busy_overlay_dialog_order_contract_test)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/input/china_input_formatters.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/id_card_utils.dart';
import '../models/employee_api_models.dart';
import '../models/employee_id_number_issue.dart';
import '../models/employee_id_types.dart';
import '../repositories/employee_repository.dart';
import 'employee_dialog_error_text.dart';

/// 证件号码最长 64 个字符(与后端 ChangeIdentityRequest 一致)。
const int kEmployeeIdNumberMaxLength = 64;

/// 打开修改证件信息弹窗；保存成功返回 true，取消返回 false。
///
/// [profile] 为空时弹窗内先读一次员工资料，用来带出当前证件类型和(有权限时)号码。
Future<bool> showEmployeeIdentityCorrectionDialog(
  BuildContext context, {
  required WidgetRef ref,
  required String employeeId,
  required String employeeName,
  EmployeeProfile? profile,
}) async {
  final saved = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => EmployeeIdentityCorrectionDialog(
      repository: ref.read(employeeRepositoryProvider),
      employeeId: employeeId,
      employeeName: employeeName,
      profile: profile,
    ),
  );
  return saved == true;
}

class EmployeeIdentityCorrectionDialog extends StatefulWidget {
  const EmployeeIdentityCorrectionDialog({
    super.key,
    required this.repository,
    required this.employeeId,
    required this.employeeName,
    this.profile,
  });

  final EmployeeRepository repository;
  final String employeeId;
  final String employeeName;
  final EmployeeProfile? profile;

  @override
  State<EmployeeIdentityCorrectionDialog> createState() =>
      _EmployeeIdentityCorrectionDialogState();
}

class _EmployeeIdentityCorrectionDialogState
    extends State<EmployeeIdentityCorrectionDialog> {
  final _number = TextEditingController();
  String _idType = employeeIdTypeIdCard;
  EmployeeIdNumberIssue? _currentIssue;
  bool _loading = false;
  bool _loadFailed = false;
  bool _submitting = false;

  /// 档案里的号码是脱敏值(当前用户看不到明文)：不预填，并提示直接输入完整新号码。
  bool _masked = false;

  /// 点过保存后，空号码也要提示(未点之前只对已输入的内容做即时校验)。
  bool _attempted = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    if (profile != null) {
      _apply(profile);
    } else {
      _loading = true;
      _load();
    }
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final profile = await widget.repository.getById(widget.employeeId);
      if (!mounted) return;
      setState(() {
        _apply(profile);
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadFailed = true;
      });
    }
  }

  void _apply(EmployeeProfile profile) {
    final type = profile.idType;
    if (type != null && employeeIdTypeCodes.contains(type)) _idType = type;
    _currentIssue = profile.idNumberIssue;
    final number = profile.idNumber?.trim() ?? '';
    // 服务端按权限脱敏：没有明文权限时给的是 ****1234，绝不能当成号码带进输入框。
    _masked = number.contains('*');
    if (number.isNotEmpty && !_masked) _number.text = number;
  }

  bool get _isIdCard => _idType == employeeIdTypeIdCard;

  /// 当前输入的具体问题；null 表示可以提交。
  String? _problemOf(AppLocalizations l10n) {
    final text = _number.text;
    if (text.trim().isEmpty) {
      if (!_attempted) return null;
      return _isIdCard
          ? IdCardUtils.problemOf(text)
          : l10n.employeeIdentityCorrectNumberRequired;
    }
    if (_isIdCard) return IdCardUtils.problemOf(text);
    return text.trim().length > kEmployeeIdNumberMaxLength
        ? l10n.employeeIdentityCorrectNumberTooLong
        : null;
  }

  Future<void> _submit() async {
    if (_submitting || _loading) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _attempted = true;
      _error = null;
    });
    if (_problemOf(l10n) != null) return;
    final idNumber = _isIdCard
        ? IdCardUtils.normalize(_number.text)!
        : _number.text.trim();
    setState(() => _submitting = true);
    var succeeded = false;
    try {
      await widget.repository.changeIdentity(
        widget.employeeId,
        idType: _idType,
        idNumber: idNumber,
      );
      if (!mounted) return;
      succeeded = true;
      // 先清忙标志再 pop：遮罩的 OverlayEntry 要等宿主 dispose 才摘掉，不清的话
      // 调用方随后弹出的提示或弹窗会被它盖住。
      setState(() => _submitting = false);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _error = employeeDialogErrorText(
          error,
          l10n.employeeIdentityCorrectFailed,
        ),
      );
    } finally {
      if (mounted && !succeeded) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final problem = _problemOf(l10n);
    final currentIssue = _currentIssue;
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final errorStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    return PopScope<void>(
      canPop: !_submitting,
      child: AlertDialog(
        key: const ValueKey('employee-identity-correction-dialog'),
        title: Row(
          children: [
            const Icon(Icons.badge_outlined),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(l10n.employeeIdentityCorrectTitle)),
          ],
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_submitting)
                  UtenBusyOverlay(
                    title: l10n.employeeIdentityCorrectTitle,
                    description: l10n.employeeIdentityCorrectSaving,
                  ),
                Text(
                  widget.employeeName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (currentIssue != null && currentIssue.reason.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    l10n.employeeIdIssueReason(currentIssue.reason),
                    key: const ValueKey('employee-identity-correction-current'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: currentIssue.isError
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else ...[
                  if (_loadFailed) ...[
                    Text(l10n.employeeIdentityCorrectLoadFailed, style: muted),
                    const SizedBox(height: UtenSpacing.s8),
                  ],
                  UtenDropdownField(
                    key: const ValueKey('employee-identity-correction-type'),
                    label: l10n.employeeFieldIdType,
                    required: true,
                    value: _idType,
                    allowClear: false,
                    searchable: false,
                    enabled: !_submitting,
                    items: [
                      for (final code in employeeIdTypeCodes)
                        UtenDropdownItem(
                          value: code,
                          label: employeeIdTypeLabel(l10n, code),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _idType = value ?? _idType;
                      _error = null;
                    }),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    key: const ValueKey('employee-identity-correction-number'),
                    controller: _number,
                    enabled: !_submitting,
                    textCapitalization: TextCapitalization.characters,
                    inputFormatters: _isIdCard
                        ? ChinaInputFormatters.residentId
                        : null,
                    decoration: UtenInputDecoration(
                      InputDecoration(
                        labelText: l10n.employeeFieldIdNumber,
                        border: const OutlineInputBorder(),
                        isDense: true,
                        error: utenFieldError(problem),
                      ),
                    ),
                    onChanged: (_) => setState(() => _error = null),
                    onSubmitted: (_) => _submit(),
                  ),
                  // 具体哪里不对再用红字明确写出来(输入框里的错误只是个小图标)。
                  if (problem != null) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        problem,
                        key: const ValueKey(
                          'employee-identity-correction-problem',
                        ),
                        style: errorStyle,
                      ),
                    ),
                  ],
                  const SizedBox(height: UtenSpacing.s8),
                  if (_isIdCard)
                    Text(l10n.employeeIdentityCorrectHint, style: muted),
                  if (_masked) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(l10n.employeeIdentityCorrectNoPrefill, style: muted),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      key: const ValueKey('employee-identity-correction-error'),
                      style: errorStyle,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            key: const ValueKey('employee-identity-correction-cancel'),
            onPressed: _submitting
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton.icon(
            key: const ValueKey('employee-identity-correction-save'),
            onPressed: _submitting || _loading ? null : _submit,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_rounded),
            label: Text(
              _submitting
                  ? l10n.employeeIdentityCorrectSaving
                  : l10n.commonSave,
            ),
          ),
        ],
      ),
    );
  }
}
