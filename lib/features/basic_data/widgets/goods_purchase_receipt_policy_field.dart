// 货品详情「采购」区的采购允许超收% (ADR-144)。
//
// - [GoodsPurchaseOverReceiptViewCell]：查看态一格，显示记忆值；货品可编辑时
//   (宿主按货品详情的可编辑能力传 onEdit) 带一个修改按钮。
// - [showGoodsPurchaseReceiptPolicyDialog]：只改这一个记忆值的小弹窗，经
//   PUT /master/goods/{id}/purchase-receipt-policy 保存；价格、成本与其它货品字段
//   都不动，也不需要成本查看权限。
//
// 记忆的用法：新开采购订货单选这个货品时按它预填「允许超收%」(黄框提醒核对)；
// 每次保存订货单会自动记住最后填写的非空值。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/goods_node.dart';
import '../repositories/goods_purchase_receipt_policy_repository.dart';

/// 采购允许超收% 的显示文字：5 → 5%；空 = 未设(不允许超收)。
String goodsPurchaseOverReceiptText(double? pct) {
  if (pct == null) return '未设(不允许超收)';
  final text = pct == pct.roundToDouble()
      ? pct.toInt().toString()
      : pct
            .toStringAsFixed(2)
            .replaceFirst(RegExp(r'0+$'), '')
            .replaceFirst(RegExp(r'\.$'), '');
  return '$text%';
}

/// 查看态一格：标签、记忆值、可选修改按钮。
class GoodsPurchaseOverReceiptViewCell extends StatelessWidget {
  const GoodsPurchaseOverReceiptViewCell({
    super.key,
    required this.pct,
    this.onEdit,
  });

  final double? pct;

  /// 为空时不显示修改按钮 (货品不可编辑)。
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('goods-purchase-over-receipt-view'),
      width: double.infinity,
      padding: const EdgeInsetsDirectional.only(
        start: UtenSpacing.s12,
        end: UtenSpacing.s4,
        top: UtenSpacing.s8,
        bottom: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '采购允许超收%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  goodsPurchaseOverReceiptText(pct),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: pct == null
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                  ),
                ),
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              key: const ValueKey('goods-purchase-over-receipt-edit'),
              tooltip: '修改采购允许超收%',
              icon: const Icon(Icons.edit_outlined, size: 20),
              color: theme.colorScheme.primary,
              onPressed: onEdit,
            ),
        ],
      ),
    );
  }
}

/// 打开采购允许超收% 弹窗。
///
/// 返回 true 表示宿主应重新加载货品详情：已保存，或服务端因版本过期拒绝
/// (重新加载拿到新版本后可再改)。取消或未改动返回 false。
/// 保存请求进行中弹窗不能关闭 (否则服务端已保存而宿主不重载，下次会版本冲突)。
Future<bool> showGoodsPurchaseReceiptPolicyDialog(
  BuildContext context, {
  required GoodsDetail detail,
}) async {
  final reload = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoodsPurchaseReceiptPolicyDialog(detail: detail),
  );
  return reload == true;
}

class _GoodsPurchaseReceiptPolicyDialog extends ConsumerStatefulWidget {
  const _GoodsPurchaseReceiptPolicyDialog({required this.detail});

  final GoodsDetail detail;

  @override
  ConsumerState<_GoodsPurchaseReceiptPolicyDialog> createState() =>
      _GoodsPurchaseReceiptPolicyDialogState();
}

class _GoodsPurchaseReceiptPolicyDialogState
    extends ConsumerState<_GoodsPurchaseReceiptPolicyDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.detail.purchaseAllowedOverReceiptPct == null
        ? ''
        : goodsPurchaseOverReceiptText(
            widget.detail.purchaseAllowedOverReceiptPct,
          ).replaceFirst('%', ''),
  );
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _goodsLabel {
    final d = widget.detail;
    final name = d.name?.trim() ?? '';
    final code = d.code?.trim() ?? '';
    final head = name.isEmpty ? code : (code.isEmpty ? name : '$name($code)');
    final color = d.colorName?.trim() ?? '';
    return color.isEmpty ? head : '$head · $color';
  }

  Future<void> _save() async {
    final parsed = parseGoodsPurchaseOverReceiptPct(_controller.text);
    if (!parsed.valid) {
      setState(() => _error = '请填写 0 到 100 之间的数，最多两位小数；留空表示不预填');
      return;
    }
    if (parsed.value == widget.detail.purchaseAllowedOverReceiptPct) {
      Navigator.of(context).pop(false);
      return;
    }
    final version = widget.detail.version;
    if (version == null) {
      setState(() => _error = '货品资料版本未知，请关闭后刷新货品再改');
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    Object? failure;
    try {
      await ref
          .read(goodsPurchaseReceiptPolicyRepositoryProvider)
          .update(widget.detail.id, pct: parsed.value, version: version);
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (failure != null) {
      context.appApiError(failure);
      // 409 = 有人同时改了这个货品：关闭并让宿主重载，下次带新版本。
      if (failure is ApiException && failure.httpStatus == 409) {
        Navigator.of(context).pop(true);
      }
      return;
    }
    context.appSuccess(parsed.value == null ? '已清除采购允许超收设置' : '采购允许超收已保存');
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = _goodsLabel;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        key: const ValueKey('goods-purchase-over-receipt-dialog'),
        title: const Text('采购允许超收%'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (label.isNotEmpty) ...[
                  Text(
                    label,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                ],
                Text(
                  '供应商送货允许多于订货量的比例。例如填 5，订 100 件累计最多可收 105 件，'
                  '在这以内照常入库、立应付；超过的部分才转财务审批。'
                  '这里是货品记忆：新开采购订货单时按它预填(黄框提醒核对)，'
                  '每次保存订货单会自动记住最后填写的值。留空 = 清除记忆。',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s16),
                UtenInput(
                  key: const ValueKey('goods-purchase-over-receipt-input'),
                  label: '采购允许超收%',
                  hint: '0 到 100，最多两位小数',
                  controller: _controller,
                  errorMessage: _error,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                    LengthLimitingTextInputFormatter(6),
                  ],
                ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        // 适老化触控基线: 弹窗两个按钮都用大号(52), 不小于 48。
        actions: [
          UtenButton(
            key: const ValueKey('goods-purchase-over-receipt-cancel'),
            type: UtenButtonType.ghost,
            size: UtenButtonSize.large,
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          UtenActionButton(
            key: const ValueKey('goods-purchase-over-receipt-save'),
            size: UtenActionButtonSize.large,
            icon: Icons.save_outlined,
            label: const Text('保存'),
            loadingLabel: const Text('保存中…'),
            onAction: _save,
          ),
        ],
      ),
    );
  }
}
