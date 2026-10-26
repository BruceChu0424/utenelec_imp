import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;

Future<void> postB2HarnessEvidence(Map<String, Object?> result) async {
  final origin = Uri.base;
  if (origin.scheme != 'http' ||
      origin.host != '127.0.0.1' ||
      origin.port != 53626) {
    throw StateError('Only the isolated B2 loopback collector is allowed');
  }
  final response = await web.window
      .fetch(
        origin.resolve('/b0-results').toString().toJS,
        web.RequestInit(
          method: 'POST',
          headers: web.Headers()..set('Content-Type', 'application/json'),
          body: jsonEncode(result).toJS,
          credentials: 'omit',
          mode: 'same-origin',
          redirect: 'error',
          cache: 'no-store',
        ),
      )
      .toDart;
  if (response.status != 204) throw StateError('Collector refused the sample');
}
