import 'package:flutter/material.dart';

import '../../core/responsive/display_zoom.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_close_button.dart';
import '../inputs/uten_field_hint_icon.dart';

/// Decorative panel spacing stays stable in window pixels when the user changes
/// the application zoom. Text and control hit targets retain their own sizing.
abstract final class UtenPanelSpacing {
  static double inset(BuildContext context, double value) =>
      value / UtenDisplayScale.fontZoomOf(context);

  static EdgeInsets header(BuildContext context) => EdgeInsets.fromLTRB(
    inset(context, UtenSpacing.s16),
    inset(context, UtenSpacing.s8),
    inset(context, UtenSpacing.s8),
    inset(context, UtenSpacing.s8),
  );

  static EdgeInsets body(BuildContext context) =>
      EdgeInsets.all(inset(context, UtenSpacing.s12));

  /// Browsing panes already provide their own search/table top inset.
  static EdgeInsets browseBody(BuildContext context) => EdgeInsets.fromLTRB(
    inset(context, UtenSpacing.s12),
    0,
    inset(context, UtenSpacing.s12),
    inset(context, UtenSpacing.s12),
  );

  static EdgeInsets search(BuildContext context) =>
      EdgeInsets.symmetric(vertical: inset(context, UtenSpacing.s8));
}

/// Shared compact heading for side panels and selection sheets. The close
/// control uses the project control metrics rather than an implicit 48 px
/// IconButton plus a second layer of large vertical padding.
class UtenPanelHeader extends StatelessWidget {
  const UtenPanelHeader({
    super.key,
    required this.title,
    required this.onClose,
    this.subtitle,
    this.info,
    this.leading,
    this.actions = const [],
    this.titleStyle,
    this.closeTooltip = '关闭',
    this.closeButtonKey,
  });

  final String title;
  final String? subtitle;
  final String? info;
  final VoidCallback? onClose;
  final Widget? leading;
  final List<Widget> actions;
  final TextStyle? titleStyle;
  final String closeTooltip;
  final Key? closeButtonKey;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: UtenPanelSpacing.header(context),
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style:
                            titleStyle ??
                            theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    if (info?.trim().isNotEmpty ?? false)
                      UtenFieldHintIcon(info: info, dense: true),
                  ],
                ),
                if (subtitle?.trim().isNotEmpty ?? false)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          ...actions,
          UtenCloseButton(
            key: closeButtonKey,
            tooltip: closeTooltip,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}
