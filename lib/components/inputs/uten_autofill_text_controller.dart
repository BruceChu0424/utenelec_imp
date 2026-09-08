import 'package:flutter/material.dart';

/// Keeps review state with the value when an editable grid remounts its cells.
/// Selection, focus and composing-range changes do not confirm a learned value.
class UtenAutofillTextController extends TextEditingController {
  UtenAutofillTextController({super.text, bool autofilled = true})
    : _autofilled = autofilled && (text?.trim().isNotEmpty ?? false);

  bool _autofilled;
  bool get autofilled => _autofilled;

  @override
  set value(TextEditingValue next) {
    if (next.text != super.value.text) _autofilled = false;
    super.value = next;
  }

  /// A caller must explicitly identify a fresh automatic suggestion.
  void setAutomaticText(String text) {
    _autofilled = text.trim().isNotEmpty;
    final previous = value;
    final next = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    super.value = next;
    // Same-text suggestions can still change the review state.
    if (previous == next) notifyListeners();
  }
}
