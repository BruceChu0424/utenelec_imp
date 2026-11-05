import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../components/layout/uten_adaptive_panel.dart';

/// Contextual finance work keeps its report visible behind a single adaptive
/// panel. The owning form retains all draft, identity and pending-write guards.
/// Short confirmations and reauthentication continue to use their own dialogs.
Future<T?> showFinanceWorkbenchPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  double widthFraction = UtenPanelWidth.browse,
  double minimumWidth = 840,
}) => showUtenAdaptivePanel<T>(
  context: context,
  drawerWidth: minimumWidth,
  widthFraction: widthFraction,
  compactHeightFactor: .94,
  barrierDismissible: false,
  enableDrag: false,
  builder: (context) =>
      UtenEmbeddedDialogScope(child: Builder(builder: builder)),
);
