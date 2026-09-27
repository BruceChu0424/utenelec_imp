import 'dart:js_interop';
import 'package:web/web.dart' as web;

void Function() registerFormDraftLifecycle(void Function() flush) {
  final listener = ((web.Event _) => flush()).toJS;
  web.window.addEventListener('pagehide', listener);
  web.document.addEventListener('visibilitychange', listener);
  return () {
    web.window.removeEventListener('pagehide', listener);
    web.document.removeEventListener('visibilitychange', listener);
  };
}
