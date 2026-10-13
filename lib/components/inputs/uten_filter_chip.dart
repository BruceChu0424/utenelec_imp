import 'package:flutter/material.dart';

import '../../core/responsive/scale.dart';
import '../../core/theme/uten_tokens.dart';

/// A selectable filter with complete labels and native chip interaction.
///
/// Native chips measure the label before reserving their checkmark, then narrow
/// it without increasing its measured height. Keep the decoration in the label
/// so both layout passes use the same width, including in intrinsic table UI.
class UtenFilterChip extends FilterChip {
  const UtenFilterChip({
    super.key,
    required super.label,
    super.avatar,
    super.selected,
    required super.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final extent = UtenControlMetrics.minimumHitExtent(context);
    final iconExtent = context.scaled(18);
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: extent, minHeight: extent),
      child: FilterChip(
        selected: selected,
        onSelected: onSelected,
        showCheckmark: false,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: EdgeInsets.zero,
        labelPadding: EdgeInsets.zero,
        label: Builder(
          builder: (labelContext) => DefaultTextStyle(
            style: DefaultTextStyle.of(labelContext).style,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  if (selected || avatar != null)
                    SizedBox(
                      width: iconExtent,
                      height: iconExtent,
                      child: selected
                          ? Icon(Icons.check, size: iconExtent)
                          : Center(child: avatar),
                    ),
                  label,
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
