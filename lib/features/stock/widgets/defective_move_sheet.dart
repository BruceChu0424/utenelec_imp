// 不良品处置面板(ADR-146)：「转不良品仓」(良品仓 -> 不良品仓) / 「不良复判转回」(不良品仓 -> 良品仓)。
//
// 从库存详情的某一仓余额行打开：货品、颜色、来源仓带入；调出/调入仓都用全站右侧滑窗选
// (按用途过滤, 只能选对应类别的启用子仓)；必须写原因。提交 = 服务端一次建单并过账,
// 同一面板内重试沿用同一个提交键, 不会重复过账。发出后结果未知(超时/断网/5xx)时内容锁定,
// 只能按原内容重试(服务端对同键不同内容回 409, 不会把改过的数量当成已办成)。
// 「转不良品仓」不被预留挡住; 转走后已经没有实物的预留由服务端列出, 这里提醒办理人。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/inputs/uten_filter_picker_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../repositories/defective_move_repository.dart';

/// 打开不良品处置面板；过账成功返回 true。
Future<bool> showDefectiveMoveSheet(
  BuildContext context, {
  required String kind,
  required String goodsId,
  required String goodsName,
  String? colorId,
  String? colorName,
  String? unitId,
  String? unitName,
  String? fromWarehouseId,
}) async {
  final result = await showUtenAdaptivePanel<bool>(
    context: context,
    builder: (_) => DefectiveMoveSheet(
      kind: kind,
      goodsId: goodsId,
      goodsName: goodsName,
      colorId: colorId,
      colorName: colorName,
      unitId: unitId,
      unitName: unitName,
      fromWarehouseId: fromWarehouseId,
    ),
  );
  return result == true;
}

class DefectiveMoveSheet extends ConsumerStatefulWidget {
  const DefectiveMoveSheet({
    super.key,
    required this.kind,
    required this.goodsId,
    required this.goodsName,
    this.colorId,
    this.colorName,
    this.unitId,
    this.unitName,
    this.fromWarehouseId,
  });

  final String kind;
  final String goodsId;
  final String goodsName;
  final String? colorId;
  final String? colorName;
  final String? unitId;
  final String? unitName;
  final String? fromWarehouseId;

  @override
  ConsumerState<DefectiveMoveSheet> createState() => _DefectiveMoveSheetState();
}

class _DefectiveMoveSheetState extends ConsumerState<DefectiveMoveSheet> {
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  late final String _requestKey = _newRequestKey();
  String? _from;
  String? _to;
  bool _submitted = false;

  /// 上次提交已发出但结果未知: 内容锁定, 只能按原内容重试。
  bool _uncertain = false;

  bool get _toDefective => widget.kind == DefectiveMoveKind.toDefective;
  WarehouseUse get _fromUse =>
      _toDefective ? WarehouseUse.goodOut : WarehouseUse.defectiveOut;
  WarehouseUse get _toUse =>
      _toDefective ? WarehouseUse.defectiveIn : WarehouseUse.goodIn;

  @override
  void initState() {
    super.initState();
    final names = ref.read(masterNameServiceProvider);
    final from = widget.fromWarehouseId;
    if (from != null &&
        WarehouseSelection(
          names.warehouseHierarchy,
          use: _fromUse,
        ).selectableIds.contains(from)) {
      _from = from;
    }
  }

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  static String _newRequestKey() {
    final random = math.Random.secure();
    final suffix = List.generate(
      12,
      (_) => random.nextInt(36).toRadixString(36),
    ).join();
    return 'dm-${DateTime.now().millisecondsSinceEpoch}-$suffix';
  }

  Future<void> _pick(bool from) async {
    if (_uncertain) return;
    final names = ref.read(masterNameServiceProvider);
    await names.ensureWarehousesLoaded();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final picked = await showUtenWarehousePickerPanel(
      context,
      hierarchy: names.warehouseHierarchy,
      use: from ? _fromUse : _toUse,
      initialWarehouseId: from ? _from : _to,
      title: from ? l10n.defectiveMoveFrom : l10n.defectiveMoveTo,
    );
    if (picked == null || picked.isAll || !mounted) return;
    setState(() => from ? _from = picked.id : _to = picked.id);
  }

  double? get _qtyValue {
    final value = double.tryParse(_qty.text.trim());
    return value == null || value <= 0 ? null : value;
  }

  Future<void> _submit() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _submitted = true);
    final qty = _qtyValue;
    final reason = _reason.text.trim();
    if (_from == null ||
        _to == null ||
        qty == null ||
        reason.isEmpty ||
        reason.length > 500) {
      context.appWarning(l10n.defectiveMoveIncomplete);
      return;
    }
    try {
      final created = await ref
          .read(defectiveMoveRepositoryProvider)
          .create(
            kind: widget.kind,
            fromWarehouseId: _from!,
            toWarehouseId: _to!,
            reason: reason,
            requestKey: _requestKey,
            goodsId: widget.goodsId,
            colorId: widget.colorId,
            unitId: widget.unitId,
            qty: qty,
          );
      if (!mounted) return;
      context.appSuccess(l10n.defectiveMoveDone(created.billNo));
      if (created.warnings.isNotEmpty) {
        context.appWarning(
          created.warnings.join('\n'),
          title: l10n.defectiveMoveReservationWarning,
          force: true,
        );
      }
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      // 发出后没拿到明确答复: 结果未知, 锁定内容只许原样重试; 服务端明确拒绝(4xx)时什么都没办, 可以改了再提交。
      final uncertain =
          error is! ApiException ||
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.httpStatus == null ||
          error.httpStatus! >= 500;
      setState(() => _uncertain = uncertain);
      context.appApiError(error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final title = _toDefective
        ? l10n.defectiveMoveToDefective
        : l10n.defectiveMoveRelease;
    final goods = [
      widget.goodsName,
      if (widget.colorName != null && widget.colorName!.isNotEmpty)
        widget.colorName!,
    ].join(' · ');
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                  onPressed: () => Navigator.of(context).pop(false),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
            Text(
              _toDefective
                  ? l10n.defectiveMoveToDefectiveExplain
                  : l10n.defectiveMoveReleaseExplain,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            Text(
              l10n.defectiveMoveGoods,
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              goods,
              key: const Key('defective-move-goods'),
              style: theme.textTheme.bodyLarge,
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (_uncertain) ...[
              UtenInlineNotice(
                key: const Key('defective-move-uncertain'),
                level: UtenInlineNoticeLevel.warning,
                message: l10n.defectiveMoveUncertain,
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
            UtenFilterPickerField(
              key: const Key('defective-move-from'),
              label: l10n.defectiveMoveFrom,
              value: _from == null ? null : names.warehouse(_from),
              placeholder: '—',
              width: null,
              icon: Icons.warehouse_outlined,
              enabled: !_uncertain,
              onTap: () => _pick(true),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenFilterPickerField(
              key: const Key('defective-move-to'),
              label: l10n.defectiveMoveTo,
              value: _to == null ? null : names.warehouse(_to),
              placeholder: '—',
              width: null,
              icon: Icons.warehouse_outlined,
              enabled: !_uncertain,
              onTap: () => _pick(false),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              key: const Key('defective-move-qty'),
              label: widget.unitName == null || widget.unitName!.isEmpty
                  ? l10n.defectiveMoveQty
                  : '${l10n.defectiveMoveQty} (${widget.unitName})',
              controller: _qty,
              required: true,
              enabled: !_uncertain,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              errorMessage: _submitted && _qtyValue == null
                  ? l10n.defectiveMoveIncomplete
                  : null,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenInput(
              key: const Key('defective-move-reason'),
              label: l10n.defectiveMoveReason,
              hint: _toDefective
                  ? l10n.defectiveMoveReasonHintToDefective
                  : l10n.defectiveMoveReasonHintRelease,
              controller: _reason,
              required: true,
              enabled: !_uncertain,
              maxLines: 3,
              errorMessage: _submitted && _reason.text.trim().isEmpty
                  ? l10n.defectiveMoveIncomplete
                  : null,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: UtenSpacing.s16),
            UtenActionButton(
              key: const Key('defective-move-submit'),
              onAction: _submit,
              label: Text(l10n.defectiveMoveSubmit),
              isExpanded: true,
            ),
          ],
        ),
      ),
    );
  }
}
