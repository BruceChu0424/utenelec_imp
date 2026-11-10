import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../feedback/uten_busy_overlay.dart';
import '../feedback/uten_date_range_picker.dart';
import '../layout/uten_app_bar_action_scope.dart';
import 'uten_button.dart';

/// One year entry, with the same calendar and filter geometry as date ranges.
class UtenYearSelectionButton extends StatefulWidget {
  const UtenYearSelectionButton({
    super.key,
    required this.year,
    required this.onChanged,
    this.firstYear = 2010,
    this.lastYear = 2100,
    this.enabled = true,
  });

  final int year;
  final int firstYear;
  final int lastYear;
  final bool enabled;
  final FutureOr<void> Function(int year) onChanged;

  @override
  State<UtenYearSelectionButton> createState() =>
      _UtenYearSelectionButtonState();
}

class _UtenYearSelectionButtonState extends State<UtenYearSelectionButton> {
  bool _picking = false;
  bool _applying = false;

  Future<void> _pick() async {
    if (!widget.enabled || _picking) return;
    final owner = UtenActionOwnerScope.identityOf(context);
    final change = widget.onChanged;
    setState(() => _picking = true);
    try {
      final year = await showUtenYearPicker(
        context: context,
        firstYear: widget.firstYear,
        lastYear: widget.lastYear,
        initialYear: widget.year,
      );
      if (!mounted ||
          !widget.enabled ||
          owner != UtenActionOwnerScope.identityOf(context) ||
          year == null ||
          year == widget.year) {
        return;
      }
      final pending = change(year);
      if (pending is Future) {
        setState(() => _applying = true);
        await pending;
      }
    } finally {
      if (mounted) {
        setState(() {
          _picking = false;
          _applying = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      UtenButton(
        type: UtenButtonType.secondary,
        height: UtenFilterRow.heightOf(context),
        icon: Icons.calendar_today_outlined,
        onPressed: widget.enabled && !_picking ? _pick : null,
        child: Text('${widget.year}'),
      ),
      if (_applying)
        const UtenBusyOverlay(title: '正在查询报表', showDoNotLeaveHint: false),
    ],
  );
}
