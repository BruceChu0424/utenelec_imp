import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;

/// VM fixtures always read the canonical repository file. Browser fixtures
/// receive that file's exact bytes through the controlled test command.
String readCanonicalContractText({
  required String path,
  required String compileTimeBase64,
  required String defineName,
}) {
  if (!kIsWeb) return File(path).readAsStringSync();
  return decodeCanonicalContractText(
    encoded: compileTimeBase64,
    path: path,
    defineName: defineName,
  );
}

String decodeCanonicalContractText({
  required String encoded,
  required String path,
  required String defineName,
}) {
  if (encoded.isEmpty) {
    throw StateError('Missing $defineName for canonical contract $path');
  }
  try {
    final bytes = base64Decode(encoded);
    if (base64Encode(bytes) != encoded) throw const FormatException();
    return utf8.decode(bytes);
  } on FormatException {
    throw StateError('Invalid Base64 or UTF-8 in $defineName for $path');
  }
}
