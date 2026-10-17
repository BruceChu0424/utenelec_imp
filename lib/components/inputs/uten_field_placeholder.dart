import 'package:flutter/material.dart';

import 'uten_field_label.dart';

/// Ordinary empty fields show their business name, without request verbs.
/// Search fields without a label retain their complete search scope.
String? utenFieldPlaceholder({String? label, String? hint, String? fallback}) {
  String? clean(String? source, {bool isHint = false}) {
    if (source == null) return null;
    final value = source
        .trim()
        .replaceFirst(
          RegExp(
            isHint
                ? r'^(?:请\s*)?(?:输入|选择|填写|录入|选取|键入)\s*'
                : r'^请\s*(?:输入|选择|填写|录入|选取|键入)\s*',
          ),
          '',
        )
        .replaceFirst(
          RegExp(
            isHint
                ? r'^(?:please\s+)?(?:enter|select|choose|input|type)\s+'
                : r'^please\s+(?:enter|select|choose|input|type)\s+',
            caseSensitive: false,
          ),
          '',
        )
        .replaceFirst(RegExp(r'\s*[*＊]\s*$'), '')
        .trim();
    return value.isEmpty ? null : value;
  }

  return clean(label) ?? clean(hint, isHint: true) ?? clean(fallback);
}

/// Read shared required/info labels without changing their visual red marker.
String? utenDecorationFieldName(InputDecoration decoration) {
  String? text(Widget? widget) => switch (widget) {
    UtenFieldLabel(:final labelWithoutInfo) => text(labelWithoutInfo),
    Text(:final data, :final textSpan) => data ?? textSpan?.toPlainText(),
    RichText(:final text) => text.toPlainText(),
    _ => null,
  };
  return utenFieldPlaceholder(
    label: decoration.labelText ?? text(decoration.label),
  );
}
