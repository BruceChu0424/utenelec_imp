import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

@JS('window.utenWebUpdateBranding')
external set _publishedBranding(JSObject value);

String? _lastPublished;

void publishWebUpdateBranding(Map<String, Object?> branding) {
  final fingerprint = jsonEncode(branding);
  if (_lastPublished == fingerprint) return;
  _lastPublished = fingerprint;
  final value = branding.jsify() as JSObject;
  _publishedBranding = value;
  web.window.dispatchEvent(
    web.CustomEvent(
      'uten:web-update-branding',
      web.CustomEventInit(detail: value),
    ),
  );
}
