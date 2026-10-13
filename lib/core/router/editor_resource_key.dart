import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';

/// Editors own the actual document and prefilled source, not the router's
/// template page key. Returning elsewhere changes navigation, not form input.
ValueKey<String> editorResourceKey(Uri uri, {Object? sourceIdentity}) {
  final query = {
    for (final entry in uri.queryParametersAll.entries)
      if (entry.key != 'returnTo') entry.key: entry.value,
  };
  final identity = _canonical({
    'path': uri.path,
    'query': query,
    'source': sourceIdentity,
  });
  return ValueKey(
    'editor-${sha256.convert(utf8.encode(jsonEncode(identity)))}',
  );
}

Object? _canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _canonical(value[key])};
  }
  if (value is Iterable) return value.map(_canonical).toList(growable: false);
  return value;
}
