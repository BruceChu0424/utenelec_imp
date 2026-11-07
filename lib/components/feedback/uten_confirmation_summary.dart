import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// One quantity, count, or other decisive fact shown before a write.
class UtenConfirmationFact {
  const UtenConfirmationFact({required this.label, required this.value});

  final String label;
  final String value;
}

/// Compact facts and critical consequences shared by secondary confirmations.
class UtenConfirmationSummary extends StatelessWidget {
  const UtenConfirmationSummary({
    super.key,
    this.facts = const [],
    this.consequences = const [],
  });

  final List<UtenConfirmationFact> facts;
  final List<String> consequences;

  /// A complete text representation for confirmations saved with a request.
  String get plainText => [
    for (final fact in facts) '${fact.label} ${fact.value}',
    ...consequences,
  ].join('\n');

  @override
  Widget build(BuildContext context) {
    final emphasis = TextStyle(
      color: Theme.of(context).colorScheme.error,
      fontWeight: FontWeight.w700,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: UtenSpacing.s4,
      children: [
        for (final fact in facts)
          Text.rich(
            TextSpan(
              text: '${fact.label} ',
              children: [TextSpan(text: fact.value, style: emphasis)],
            ),
          ),
        if (facts.isNotEmpty && consequences.isNotEmpty)
          const SizedBox(height: UtenSpacing.s4),
        for (final consequence in consequences)
          Text(consequence, style: emphasis),
      ],
    );
  }
}
