// 其它耗用登记对话框 (ADR-131 §5.3): 试模、清机、报废料、其它的公斤数和原因。
//
// 当场从内料仓出库记车间费用, 不摊给产品, 报表单列。不登记的话差额体现在浪费率里。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/inputs/required_field_decoration.dart';
import '../../../../components/inputs/uten_dropdown_field.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

/// 打开其它耗用对话框; [materials] = 内料仓里现有的料。登记成功返回 true。
Future<bool?> showWorkshopMaterialOtherIssueDialog(
  BuildContext context, {
  required String workshopId,
  required List<WmPositionRow> materials,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => WorkshopMaterialOtherIssueDialog(
    workshopId: workshopId,
    materials: materials,
  ),
);

class WorkshopMaterialOtherIssueDialog extends ConsumerStatefulWidget {
  const WorkshopMaterialOtherIssueDialog({
    super.key,
    required this.workshopId,
    required this.materials,
  });

  final String workshopId;
  final List<WmPositionRow> materials;

  @override
  ConsumerState<WorkshopMaterialOtherIssueDialog> createState() =>
      _WorkshopMaterialOtherIssueDialogState();
}

class _WorkshopMaterialOtherIssueDialogState
    extends ConsumerState<WorkshopMaterialOtherIssueDialog> {
  final _qty = TextEditingController();
  final _reasonText = TextEditingController();
  final _nonce = const Uuid().v4();
  String? _materialKey;
  String _reason = wmOtherIssueReasons.first;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.materials.length == 1) _materialKey = widget.materials.first.key;
  }

  @override
  void dispose() {
    _qty.dispose();
    _reasonText.dispose();
    super.dispose();
  }

  WmPositionRow? get _material {
    for (final m in widget.materials) {
      if (m.key == _materialKey) return m;
    }
    return null;
  }

  String _materialName(WmPositionRow row) => [
    row.goodsName ?? row.goodsCode ?? '',
    if (row.colorName != null && row.colorName!.isNotEmpty) row.colorName!,
  ].join(' ');

  Future<void> _submit() async {
    final material = _material;
    final qty = wmParseQty(_qty.text);
    final reasonText = _reasonText.text.trim();
    final problem = material == null
        ? '请选择料'
        : (qty ?? 0) <= 0
        ? '请填公斤数'
        : _reason == 'OTHER' && reasonText.length < 2
        ? '选"其它"时请写清楚用在哪 (至少 2 个字)'
        : null;
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    final key = wmIdempotencyKey('other-issue', _nonce, {
      'workshop': widget.workshopId,
      'goods': material!.key,
      'qty': qty,
      'reason': _reason,
      'text': reasonText,
    });
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(workshopMaterialRepositoryProvider)
          .otherIssue(
            workshopDepartmentId: widget.workshopId,
            goodsId: material.goodsId,
            colorId: material.colorId,
            qty: qty!,
            reason: _reason,
            reasonText: reasonText,
            idempotencyKey: key,
          );
      if (!mounted) return;
      setState(() => _saving = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess('已登记「${_materialName(material)}」${wmQty(qty)} 公斤');
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '网络不稳定, 暂时没确认登记结果。内容已保留, 请再点一次登记 (不会重复登记)。';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_saving,
      child: Stack(
        children: [
          AlertDialog(
            title: Text(l10n.wmOtherIssue),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '试模、清机、报废的料在这里登记, 记车间费用, 不摊给产品。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    UtenDropdownField(
                      key: const Key('wm-other-issue-material'),
                      label: '料',
                      required: true,
                      enabled: !_saving,
                      allowClear: false,
                      value: _materialKey,
                      items: [
                        for (final m in widget.materials)
                          UtenDropdownItem(
                            value: m.key,
                            label: _materialName(m),
                          ),
                      ],
                      onChanged: (v) => setState(() => _materialKey = v),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    ValueListenableBuilder<TextEditingValue>(
                      valueListenable: _qty,
                      builder: (context, value, _) => TextField(
                        key: const Key('wm-other-issue-qty'),
                        controller: _qty,
                        enabled: !_saving,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: applyRequiredEmpty(
                          InputDecoration(
                            label: requiredLabel(
                              l10n.wmKg,
                              theme,
                              required: true,
                            ),
                          ),
                          theme,
                          requiredEmpty: (wmParseQty(value.text) ?? 0) <= 0,
                        ),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    Text('用在哪', style: theme.textTheme.labelLarge),
                    const SizedBox(height: UtenSpacing.s6),
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s6,
                      children: [
                        for (final reason in wmOtherIssueReasons)
                          ChoiceChip(
                            key: Key('wm-other-issue-reason-$reason'),
                            label: Text(wmOtherIssueReasonLabel(l10n, reason)),
                            selected: _reason == reason,
                            onSelected: _saving
                                ? null
                                : (_) => setState(() => _reason = reason),
                          ),
                      ],
                    ),
                    if (_reason == 'OTHER') ...[
                      const SizedBox(height: UtenSpacing.s12),
                      ValueListenableBuilder<TextEditingValue>(
                        valueListenable: _reasonText,
                        builder: (context, value, _) => TextField(
                          key: const Key('wm-other-issue-reason-text'),
                          controller: _reasonText,
                          enabled: !_saving,
                          maxLength: 200,
                          decoration: applyRequiredEmpty(
                            InputDecoration(
                              label: requiredLabel('说明', theme, required: true),
                              counterText: '',
                            ),
                            theme,
                            requiredEmpty: value.text.trim().length < 2,
                          ),
                        ),
                      ),
                    ],
                    if (_error != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(color: theme.colorScheme.error),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              UtenButton(
                key: const Key('wm-other-issue-submit'),
                isLoading: _saving,
                onPressed: _saving ? null : _submit,
                child: const Text('登记'),
              ),
            ],
          ),
          if (_saving)
            const UtenBusyOverlay(title: '正在登记', description: '正在从内料仓记出这批料'),
        ],
      ),
    );
  }
}
