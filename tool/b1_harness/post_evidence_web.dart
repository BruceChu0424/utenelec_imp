import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<void> postB1HarnessEvidence(Map<String, Object?> result) async {
  final origin = Uri.base;
  if (origin.scheme != 'http' ||
      !{'127.0.0.1', 'localhost'}.contains(origin.host) ||
      origin.port != 53881) {
    throw StateError(
      'Evidence collector only permits the dedicated loopback origin',
    );
  }
  final body = jsonEncode(result);
  if (utf8.encode(body).length > 200000) {
    throw StateError('Synthetic evidence exceeds its bounded collector budget');
  }
  final response = await web.window
      .fetch(
        origin.resolve('/b0-results').toString().toJS,
        web.RequestInit(
          method: 'POST',
          headers: web.Headers()..set('Content-Type', 'application/json'),
          body: body.toJS,
          credentials: 'omit',
          mode: 'same-origin',
          redirect: 'error',
          cache: 'no-store',
        ),
      )
      .toDart;
  if (response.status != 204) {
    throw StateError('Synthetic evidence collector rejected the measurement');
  }
}
