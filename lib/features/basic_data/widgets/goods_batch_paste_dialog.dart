import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/theme/uten_tokens.dart';
import 'basic_data_l10n.dart';

Future<int?> showGoodsBatchPasteDialog(
  BuildContext context, {
  required int goodsCount,
}) => UtenDialog.showAndWaitForExit<int>(
  context,
  builder: (_) => GoodsBatchPasteDialog(goodsCount: goodsCount),
);

/// Owns the editable count for the entire dialog route, including its exit.
class GoodsBatchPasteDialog extends StatefulWidget {
  const GoodsBatchPasteDialog({super.key, required this.goodsCount})
    : assert(goodsCount > 0);

  static const minCopies = 1;
  static const maxCopies = 50;

  final int goodsCount;

  @override
  State<GoodsBatchPasteDialog> createState() => _GoodsBatchPasteDialogState();
}

class _GoodsBatchPasteDialogState extends State<GoodsBatchPasteDialog> {
  final _controller = TextEditingController(text: '1');
  final _focusNode = FocusNode();

  int? get _copies {
    final value = int.tryParse(_controller.text);
    return value != null &&
            value >= GoodsBatchPasteDialog.minCopies &&
            value <= GoodsBatchPasteDialog.maxCopies
        ? value
        : null;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_countChanged);
  }

  void _countChanged() => setState(() {});

  @override
  void dispose() {
    _controller.removeListener(_countChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _step(int delta) {
    final copies = _copies;
    if (copies == null) return;
    final next = copies + delta;
    if (next < GoodsBatchPasteDialog.minCopies ||
        next > GoodsBatchPasteDialog.maxCopies) {
      return;
    }
    final text = next.toString();
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void _confirm() {
    final copies = _copies;
    if (copies != null) Navigator.of(context).pop(copies);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, available) =>
        _buildDialog(context, stackControls: available.maxWidth < 320),
  );

  Widget _buildDialog(BuildContext context, {required bool stackControls}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l10n = basicDataL10n(context);
    final copies = _copies;
    final invalid = copies == null;
    final border = OutlineInputBorder(
      borderRadius: UtenRadius.controlAll,
      borderSide: BorderSide(color: invalid ? scheme.error : scheme.outline),
    );
    final stepExtent = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: UtenControlMetrics.primaryHeight,
    );
    Widget stepButton({
      required String key,
      required String tooltip,
      required IconData icon,
      required bool enabled,
      required int delta,
    }) => IconButton.outlined(
      key: ValueKey(key),
      tooltip: tooltip,
      onPressed: enabled ? () => _step(delta) : null,
      style: IconButton.styleFrom(
        minimumSize: Size.square(stepExtent),
        shape: const RoundedRectangleBorder(
          borderRadius: UtenRadius.controlAll,
        ),
      ),
      icon: Icon(icon),
    );

    final decrease = stepButton(
      key: 'goods-batch-paste-decrease',
      tooltip: l10n.goodsBatchPasteDecrease,
      icon: Icons.remove_rounded,
      enabled: copies != null && copies > GoodsBatchPasteDialog.minCopies,
      delta: -1,
    );
    final increase = stepButton(
      key: 'goods-batch-paste-increase',
      tooltip: l10n.goodsBatchPasteIncrease,
      icon: Icons.add_rounded,
      enabled: copies != null && copies < GoodsBatchPasteDialog.maxCopies,
      delta: 1,
    );
    final countField = Semantics(
      label: l10n.goodsBatchPasteCopiesLabel,
      child: TextField(
        key: const ValueKey('goods-batch-paste-copies'),
        controller: _controller,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        textInputAction: TextInputAction.done,
        textAlign: TextAlign.center,
        style: theme.textTheme.headlineSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: scheme.onSurface,
        ),
        inputFormatters: [
          // Reject the whole edit: stripping punctuation could turn
          // a pasted decimal such as 1.5 into fifteen copies.
          TextInputFormatter.withFunction(
            (oldValue, newValue) => RegExp(r'^[0-9]*$').hasMatch(newValue.text)
                ? newValue
                : oldValue,
          ),
        ],
        decoration: UtenInputDecoration(
          InputDecoration(
            hintText: '1',
            suffixText: l10n.goodsBatchPasteCopiesUnit,
            suffixStyle: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            filled: true,
            fillColor: scheme.surfaceContainerLowest,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            enabledBorder: border,
            focusedBorder: border.copyWith(
              borderSide: BorderSide(
                color: invalid ? scheme.error : scheme.primary,
                width: 2,
              ),
            ),
          ),
          useFieldNameHint: false,
        ),
        onSubmitted: (_) => _confirm(),
      ),
    );

    return UtenAlertDialog(
      maxWidth: 520,
      title: UtenDialogHeading(
        title: Text(l10n.goodsBatchPasteTitle),
        icon: Icons.content_paste_rounded,
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.goodsBatchPasteClipboard(widget.goodsCount)),
          const SizedBox(height: UtenSpacing.s24),
          Text(
            l10n.goodsBatchPasteCopiesLabel,
            style: theme.textTheme.titleSmall?.copyWith(
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (stackControls) ...[
            countField,
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                Expanded(child: decrease),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: increase),
              ],
            ),
          ] else
            Row(
              children: [
                decrease,
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: countField),
                const SizedBox(width: UtenSpacing.s12),
                increase,
              ],
            ),
          const SizedBox(height: UtenSpacing.s8),
          Semantics(
            liveRegion: invalid,
            child: Text(
              invalid
                  ? l10n.goodsBatchPasteCopiesError
                  : l10n.goodsBatchPasteCopiesHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: invalid ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s24),
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.06),
              borderRadius: UtenRadius.controlAll,
              border: Border.all(color: scheme.primary.withValues(alpha: 0.16)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  liveRegion: true,
                  child: Text(
                    copies == null
                        ? l10n.goodsBatchPastePendingTotal
                        : l10n.goodsBatchPasteTotal(widget.goodsCount * copies),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  l10n.goodsBatchPasteAutoCode,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.commonCancel),
        ),
        UtenButton(
          key: const ValueKey('goods-batch-paste-confirm'),
          size: UtenButtonSize.large,
          icon: Icons.content_paste_rounded,
          onPressed: invalid ? null : _confirm,
          child: Text(l10n.bomEditPaste),
        ),
      ],
    );
  }
}
