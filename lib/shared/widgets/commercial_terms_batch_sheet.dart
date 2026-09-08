// 订货单明细「统一设置商业条款」批量面板（采购/委外共用，2026-09 行级条款改造）。
//
// 勾选多行后一次写全套条款：供应商 + 结账(结算)方式 + 币种 + 汇率 + 税率；
// 留空的项保持各行原值不变。供应商行内嵌供应商滑入面板（分类树+搜索+可内联新建）。
import 'package:flutter/material.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../presentation/workflow_field_guidance.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/inputs/uten_dropdown_field.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../../features/basic_data/widgets/uten_supplier_picker.dart';
import '../../shared/providers/master_name_provider.dart';

/// 批量设置结果：各字段 null = 用户未填（保持各行原值）。
class CommercialTermsBatchResult {
  const CommercialTermsBatchResult({
    this.supplierId,
    this.settlementMethodId,
    this.currencyId,
    this.exchangeRate,
    this.taxRate,
  });

  final String? supplierId;
  final String? settlementMethodId;
  final String? currencyId;
  final double? exchangeRate;
  final double? taxRate;

  bool get isEmpty =>
      (supplierId == null || supplierId!.isEmpty) &&
      settlementMethodId == null &&
      currencyId == null &&
      exchangeRate == null &&
      taxRate == null;
}

/// 弹出批量设置面板；取消返回 null。
/// [selectedCount] 勾选行数（标题展示）；[partyNoun] 采购「供应商」/委外「委外商」；
/// [settlementLabel] 采购「结账方式」/委外「结算方式」。
Future<CommercialTermsBatchResult?> showCommercialTermsBatchSheet(
  BuildContext context,
  WidgetRef ref, {
  required int selectedCount,
  required Map<String, String> currencyEntries,
  required Map<String, String> settlementEntries,
  String partyNoun = '供应商',
  String settlementLabel = '结账方式',
}) {
  return showModalBottomSheet<CommercialTermsBatchResult>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => _CommercialTermsBatchSheet(
      selectedCount: selectedCount,
      currencyEntries: currencyEntries,
      settlementEntries: settlementEntries,
      partyNoun: partyNoun,
      settlementLabel: settlementLabel,
    ),
  );
}

class _CommercialTermsBatchSheet extends ConsumerStatefulWidget {
  const _CommercialTermsBatchSheet({
    required this.selectedCount,
    required this.currencyEntries,
    required this.settlementEntries,
    required this.partyNoun,
    required this.settlementLabel,
  });

  final int selectedCount;
  final Map<String, String> currencyEntries;
  final Map<String, String> settlementEntries;
  final String partyNoun;
  final String settlementLabel;

  @override
  ConsumerState<_CommercialTermsBatchSheet> createState() =>
      _CommercialTermsBatchSheetState();
}

class _CommercialTermsBatchSheetState
    extends ConsumerState<_CommercialTermsBatchSheet> {
  String? _supplierId;
  String? _settlementMethodId;
  String? _currencyId;
  final _rate = TextEditingController();
  final _taxRate = TextEditingController();

  @override
  void dispose() {
    _rate.dispose();
    _taxRate.dispose();
    super.dispose();
  }

  Future<void> _pickSupplier() async {
    final picked = await showUtenSupplierPicker(
      context,
      ref,
      title: '统一设置${widget.partyNoun}',
    );
    if (picked == null || !mounted) return;
    setState(() => _supplierId = picked.id);
  }

  CommercialTermsBatchResult? _assemble() {
    final rateText = _rate.text.trim();
    final taxText = _taxRate.text.trim();
    final rate = rateText.isEmpty ? null : double.tryParse(rateText);
    final tax = taxText.isEmpty ? null : double.tryParse(taxText);
    if (rateText.isNotEmpty && (rate == null || rate <= 0)) {
      context.appError('汇率必须大于 0');
      return null;
    }
    if (taxText.isNotEmpty && (tax == null || tax < 0 || tax > 100)) {
      context.appError('税率必须填写 0 至 100 之间的百分比');
      return null;
    }
    final result = CommercialTermsBatchResult(
      supplierId: (_supplierId == null || _supplierId!.isEmpty)
          ? null
          : _supplierId,
      settlementMethodId: _settlementMethodId,
      currencyId: _currencyId,
      exchangeRate: rate,
      taxRate: tax,
    );
    if (result.isEmpty) {
      context.appError('请至少填写一项；留空的项将保持各行原值');
      return null;
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(masterNameServiceProvider);
    final supplierName = _supplierId == null
        ? null
        : (names.supplierEntries[_supplierId] ?? _supplierId);
    final items = [
      // 供应商：点击打开滑入面板（可在面板内内联新建）。
      _PickerRow(
        label: widget.partyNoun,
        value: supplierName,
        onTap: _pickSupplier,
      ),
      UtenDropdownField(
        label: widget.settlementLabel,
        info: workflowFieldText(context).workflowSettlementHint,
        value: _settlementMethodId,
        hintText: '不改',
        items: [
          for (final e in widget.settlementEntries.entries)
            UtenDropdownItem(value: e.key, label: e.value),
        ],
        onChanged: (v) => setState(() => _settlementMethodId = v),
      ),
      UtenDropdownField(
        label: '币种',
        info: workflowFieldText(context).workflowCurrencyHint,
        value: _currencyId,
        hintText: '不改',
        items: [
          for (final e in widget.currencyEntries.entries)
            UtenDropdownItem(value: e.key, label: e.value),
        ],
        onChanged: (v) => setState(() => _currencyId = v),
      ),
      TextField(
        controller: _rate,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: UtenInputDecoration(
          const InputDecoration(labelText: '汇率', hintText: '不改'),
          info: workflowFieldText(context).workflowExchangeRateHint,
        ),
      ),
      TextField(
        controller: _taxRate,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: UtenInputDecoration(
          const InputDecoration(labelText: '税率(%)', hintText: '不改'),
          info: workflowFieldText(context).workflowTaxRateHint,
        ),
      ),
    ];
    return Padding(
      padding: EdgeInsets.only(
        left: UtenSpacing.s16,
        right: UtenSpacing.s16,
        top: UtenSpacing.s12,
        // 软键盘弹起时收掉底距（跟随视口）。
        bottom: MediaQuery.viewInsetsOf(context).bottom + UtenSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.tune_rounded,
                size: 20,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '统一设置 ${widget.selectedCount} 行商业条款',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '留空的项保持各行原值；保存时按「${widget.partyNoun}+条款组合」自动拆单。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          for (final item in items) ...[
            item,
            const SizedBox(height: UtenSpacing.s12),
          ],
          Row(
            children: [
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: UtenButton(
                  icon: Icons.done_all_rounded,
                  onPressed: () {
                    final result = _assemble();
                    if (result != null) Navigator.of(context).pop(result);
                  },
                  child: const Text('应用到选中行'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 面板里的供应商选择行（点击打开滑入面板；与表头字段同款视觉）。
class _PickerRow extends StatelessWidget {
  const _PickerRow({
    required this.label,
    required this.value,
    required this.onTap,
  });

  final String label;
  final String? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasValue = value != null && value!.isNotEmpty;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          hintText: '不改',
          suffixIcon: Icon(
            hasValue ? Icons.unfold_more_rounded : Icons.search_rounded,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        child: Text(hasValue ? value! : '', style: theme.textTheme.bodyMedium),
      ),
    );
  }
}
