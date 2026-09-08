import 'package:flutter/material.dart';

import 'uten_field_hint_icon.dart';

/// Label metadata consumed by UtenInputDecoration; usable standalone as well.
class UtenFieldLabel extends StatelessWidget {
  const UtenFieldLabel({
    super.key,
    required this.labelWithoutInfo,
    required this.info,
  });

  final Widget labelWithoutInfo;
  final String info;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(child: labelWithoutInfo),
        UtenFieldHintIcon(info: info),
      ],
    );
  }
}
