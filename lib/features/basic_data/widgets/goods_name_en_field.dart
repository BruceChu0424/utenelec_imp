// Goods English name (ADR-134) on the goods detail page.
//
// - [GoodsNameEnViewCell]: read-only tile of the 基础 section. Shows the
//   English name, a "learned automatically" badge when the value came from a
//   saved customer file, and an edit button when the server capability
//   GoodsDetail.canEditNameEn is true (no local Perm check here: sales hold
//   goods:name_en:edit without goods:edit, the server decides).
// - [showGoodsNameEnDialog]: small dialog that saves only the English name
//   through PUT /master/goods/{id}/name-en. Prices and every other goods field
//   are untouched, so a salesperson can keep names current without being able
//   to change anything else.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/goods_node.dart';
import '../repositories/goods_name_en_repository.dart';
import 'basic_data_l10n.dart';

/// View-mode tile: label, value (or dash), learned badge, optional edit button.
class GoodsNameEnViewCell extends StatelessWidget {
  const GoodsNameEnViewCell({
    super.key,
    required this.nameEn,
    required this.learned,
    this.onEdit,
  });

  final String? nameEn;
  final bool learned;

  /// Null hides the edit button (no capability or detail not writable).
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = basicDataL10n(context);
    final value = nameEn?.trim() ?? '';
    return Container(
      key: const ValueKey('goods-name-en-view'),
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
                  l10n.goodsNameEnLabel,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      value.isEmpty ? '—' : value,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (learned && value.isNotEmpty)
                      Tooltip(
                        message: l10n.goodsNameEnLearnedTip,
                        child: UtenStatusBadge(
                          key: const ValueKey('goods-name-en-learned'),
                          label: l10n.goodsNameEnLearned,
                          type: UtenStatusBadgeType.info,
                          icon: Icons.auto_awesome_rounded,
                          size: UtenStatusBadgeSize.small,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (onEdit != null)
            IconButton(
              key: const ValueKey('goods-name-en-edit'),
              tooltip: l10n.goodsNameEnEdit,
              icon: const Icon(Icons.edit_outlined, size: 20),
              color: theme.colorScheme.primary,
              onPressed: onEdit,
            ),
        ],
      ),
    );
  }
}

/// Opens the English-name dialog for [detail].
///
/// Returns true when the host should reload the goods detail: the name was
/// saved, or the server rejected a stale version (reload picks up the newer
/// version so the next attempt can succeed). Returns false when cancelled or
/// nothing changed.
///
/// While the save request runs the dialog cannot be closed (no barrier tap,
/// Cancel disabled, back blocked): closing it then would skip the reload even
/// though the server saved, and the stale version would make the next save
/// fail with a conflict.
Future<bool> showGoodsNameEnDialog(
  BuildContext context, {
  required GoodsDetail detail,
}) async {
  final reload = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _GoodsNameEnDialog(detail: detail),
  );
  return reload == true;
}

class _GoodsNameEnDialog extends ConsumerStatefulWidget {
  const _GoodsNameEnDialog({required this.detail});

  final GoodsDetail detail;

  @override
  ConsumerState<_GoodsNameEnDialog> createState() => _GoodsNameEnDialogState();
}

class _GoodsNameEnDialogState extends ConsumerState<_GoodsNameEnDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.detail.nameEn ?? '',
  );
  String? _error;

  /// True while PUT /name-en is in flight; the dialog cannot be closed then.
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
    final l10n = basicDataL10n(context);
    final value = normalizeGoodsNameEnInput(_controller.text);
    if (value != null && value.length > kGoodsNameEnMaxLength) {
      setState(() => _error = l10n.goodsNameEnTooLong(kGoodsNameEnMaxLength));
      return;
    }
    if (value == normalizeGoodsNameEnInput(widget.detail.nameEn)) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() {
      _error = null;
      _saving = true;
    });
    Object? failure;
    try {
      await ref
          .read(goodsNameEnRepositoryProvider)
          .update(
            widget.detail.id,
            nameEn: value,
            version: widget.detail.version,
          );
    } catch (e) {
      failure = e;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (failure != null) {
      context.appApiError(failure);
      // 409 = someone changed this goods meanwhile: close and let the host
      // reload so the next attempt carries the new version.
      if (failure is ApiException && failure.httpStatus == 409) {
        Navigator.of(context).pop(true);
      }
      return;
    }
    context.appSuccess(
      value == null ? l10n.goodsNameEnCleared : l10n.goodsNameEnSaved,
    );
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = basicDataL10n(context);
    final label = _goodsLabel;
    // Back key / system pop is blocked while the save runs (see
    // showGoodsNameEnDialog).
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        key: const ValueKey('goods-name-en-dialog'),
        title: Text(l10n.goodsNameEnEdit),
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
                  l10n.goodsNameEnEditDescription,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s16),
                UtenInput(
                  key: const ValueKey('goods-name-en-input'),
                  label: l10n.goodsNameEnLabel,
                  hint: l10n.goodsNameEnHint,
                  controller: _controller,
                  errorMessage: _error,
                  textInputAction: TextInputAction.done,
                  inputFormatters: [
                    LengthLimitingTextInputFormatter(kGoodsNameEnMaxLength),
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
            key: const ValueKey('goods-name-en-cancel'),
            type: UtenButtonType.ghost,
            size: UtenButtonSize.large,
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          UtenActionButton(
            key: const ValueKey('goods-name-en-save'),
            size: UtenActionButtonSize.large,
            icon: Icons.save_outlined,
            label: Text(l10n.commonSave),
            loadingLabel: Text(l10n.goodsNameEnSaving),
            onAction: _save,
          ),
        ],
      ),
    );
  }
}
