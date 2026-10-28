import 'package:flutter/material.dart';

import '../../../components/data_display/uten_table_surface.dart';
import '../../../core/theme/uten_tokens.dart';

/// Shared geometry for the explorer's five real metadata columns. Both the
/// header and each file row own their last (action) cell's right divider.
class CompanyFileDetailRow extends StatelessWidget {
  const CompanyFileDetailRow({
    super.key,
    required this.name,
    required this.type,
    required this.size,
    required this.updatedBy,
    required this.updated,
    required this.leading,
    required this.trailing,
    this.header = false,
  });
  final Widget name, type, size, updatedBy, updated, leading, trailing;
  final bool header;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget cell(Widget child, {bool padded = true}) => UtenTableCellFrame(
      border: Border(right: BorderSide(color: scheme.outline, width: .5)),
      backgroundColor: header ? scheme.surfaceContainerLow : null,
      child: padded
          ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s12,
                vertical: UtenSpacing.s8,
              ),
              child: Align(alignment: Alignment.centerLeft, child: child),
            )
          : child,
    );
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(width: 44, child: cell(leading, padded: false)),
          Expanded(child: cell(name, padded: !header)),
          SizedBox(width: 80, child: cell(type, padded: !header)),
          SizedBox(width: 100, child: cell(size, padded: !header)),
          SizedBox(width: 110, child: cell(updatedBy, padded: !header)),
          SizedBox(width: 150, child: cell(updated, padded: !header)),
          SizedBox(width: 48, child: cell(trailing, padded: false)),
        ],
      ),
    );
  }
}
