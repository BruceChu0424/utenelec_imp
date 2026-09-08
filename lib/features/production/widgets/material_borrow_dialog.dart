import 'package:flutter/material.dart';

import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_material_analysis.dart';

// 现货调拨对话框（适老化）：默认数量 = min(借出方已分配, 对方缺口)，
// 确认前用大白话写清双方影响。客户端只收集输入，服务端逐项复核。
/// 借用调拨对话框的提交草稿：目标路径 + 数量 + 原因。
final class MaterialBorrowRequestDraft {
  const MaterialBorrowRequestDraft({
    required this.toMaterialLineId,
    required this.qty,
    required this.reason,
  });

  final String toMaterialLineId;
  final double qty;
  final String reason;
}

/// 现货调拨对话框（适老化）：默认数量 = min(借出方已分配, 对方缺口)，
/// 确认前用大白话写清双方影响。客户端只收集输入，服务端逐项复核。
class MaterialBorrowDialog extends StatefulWidget {
  const MaterialBorrowDialog({
    super.key,
    required this.from,
    required this.candidates,
    required this.productsById,
    required this.pathLabelOf,
    required this.qtyText,
  });

  final ProductionMaterialAnalysisMaterial from;
  final List<ProductionMaterialAnalysisMaterial> candidates;
  final Map<String, ProductionMaterialAnalysisProduct> productsById;
  final String Function(ProductionMaterialAnalysisMaterial) pathLabelOf;
  final String Function(double?) qtyText;

  @override
  State<MaterialBorrowDialog> createState() => _MaterialBorrowDialogState();
}

class _MaterialBorrowDialogState extends State<MaterialBorrowDialog> {
  String? _toMaterialLineId;
  late final TextEditingController _qtyController;
  late final TextEditingController _reasonController;
  String? _qtyError;

  @override
  void initState() {
    super.initState();
    _qtyController = TextEditingController();
    _reasonController = TextEditingController();
  }

  @override
  void dispose() {
    _qtyController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  ProductionMaterialAnalysisMaterial? get _target {
    for (final candidate in widget.candidates) {
      if (candidate.materialLineId == _toMaterialLineId) return candidate;
    }
    return null;
  }

  double get _maxQty {
    final target = _target;
    if (target == null) return 0;
    return widget.from.allocatedAvailableQty < target.shortageQty
        ? widget.from.allocatedAvailableQty
        : target.shortageQty;
  }

  void _selectTarget(String? materialLineId) {
    setState(() {
      _toMaterialLineId = materialLineId;
      _qtyError = null;
      // 默认值先行：数量自动填"能调的最大值"，员工只改例外。
      _qtyController.text = widget.qtyText(_maxQty);
    });
  }

  void _submit() {
    final target = _target;
    if (target == null) return;
    final qty = double.tryParse(_qtyController.text.trim());
    if (qty == null || qty <= 0) {
      setState(() => _qtyError = '请填写大于 0 的调拨数量');
      return;
    }
    if (qty > _maxQty) {
      setState(
        () => _qtyError =
            '最多可调 ${widget.qtyText(_maxQty)} 件'
            '(不超过借出方已分配量，也不超过对方缺口)',
      );
      return;
    }
    final reason = _reasonController.text.trim();
    if (reason.length < 2) return;
    Navigator.pop(
      context,
      MaterialBorrowRequestDraft(
        toMaterialLineId: target.materialLineId,
        qty: qty,
        reason: reason,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fromProduct = widget.productsById[widget.from.analysisLineId];
    final fromProductLabel =
        fromProduct?.goodsName ?? fromProduct?.goodsCode ?? '当前产品';
    final target = _target;
    final toProduct = target == null
        ? null
        : widget.productsById[target.analysisLineId];
    final qty = double.tryParse(_qtyController.text.trim());
    return AlertDialog(
      key: const Key('material-borrow-dialog'),
      title: const Text('分析内调给产品'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '把「$fromProductLabel」已分配的 '
                '${widget.from.goodsName ?? widget.from.goodsCode ?? '该物料'} '
                '现货调给更急的产品。',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '这里仅调整当前物料分析内的产品分配。若接受方在其它分析，'
                '请使用“跨计划让料”；原计划会标记优先待补，接受计划无需返还。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '可调上限：已分配 ${widget.qtyText(widget.from.allocatedAvailableQty)} 件',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '调给哪个产品(只列出缺这种料的)：',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              RadioGroup<String>(
                groupValue: _toMaterialLineId,
                onChanged: _selectTarget,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final candidate in widget.candidates)
                      RadioListTile<String>(
                        key: ValueKey(
                          'material-borrow-target-${candidate.materialLineId}',
                        ),
                        value: candidate.materialLineId,
                        title: Text(
                          widget
                                  .productsById[candidate.analysisLineId]
                                  ?.goodsName ??
                              widget
                                  .productsById[candidate.analysisLineId]
                                  ?.goodsCode ??
                              '未命名产品',
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        subtitle: Text(
                          '路径：${widget.pathLabelOf(candidate)} · '
                          '缺 ${widget.qtyText(candidate.shortageQty)} 件',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: const Key('material-borrow-qty'),
                controller: _qtyController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => setState(() => _qtyError = null),
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '调拨数量(件)',
                      theme,
                      info: target == null
                          ? '先选择调给哪个产品'
                          : '最多 ${widget.qtyText(_maxQty)} 件',
                    ),
                    error: utenFieldError(_qtyError),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              TextField(
                key: const Key('material-borrow-reason'),
                controller: _reasonController,
                minLines: 2,
                maxLines: 4,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    label: fieldLabel(
                      '调拨原因(必填)',
                      theme,
                      info: '会写入审计记录，例如"客户 X 加急，先保这单"。',
                    ),
                  ),
                ),
              ),
              if (target != null && qty != null && qty > 0) ...[
                const SizedBox(height: UtenSpacing.s12),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Text(
                    '确认后：「$fromProductLabel」会重新缺 '
                    '${widget.qtyText(qty)} 件该料；'
                    '「${toProduct?.goodsName ?? toProduct?.goodsCode ?? '对方产品'}」'
                    '缺口减少 ${widget.qtyText(qty)} 件。'
                    '正式下达采购/生产前都可以撤销。',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('material-borrow-confirm'),
          onPressed: _toMaterialLineId == null ? null : _submit,
          child: const Text('确认分析内调配'),
        ),
      ],
    );
  }
}
