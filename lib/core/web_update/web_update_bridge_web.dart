import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_update_safety.dart';

@JS('window.utenWebUpdateSafety')
external set _publishedSafety(JSObject value);

@JS('window.utenWebUpdateSafetyProbe')
external set _safetyProbe(JSFunction value);

bool _installed = false;

/// One bridge for this app lifetime. Older pages without it stay unknown.
void installWebUpdateSafetyBridge() {
  if (_installed) return;
  _installed = true;
  var scheduled = false;

  JSObject publish() {
    final value = webUpdateSafety.snapshot.toJson().jsify() as JSObject;
    _publishedSafety = value;
    web.window.dispatchEvent(
      web.CustomEvent(
        'uten:web-update-safety',
        web.CustomEventInit(detail: value),
      ),
    );
    return value;
  }

  void schedulePublish() {
    if (scheduled) return;
    scheduled = true;
    scheduleMicrotask(() {
      scheduled = false;
      publish();
    });
  }

  _safetyProbe = (() => publish()).toJS;
  webUpdateSafety.addListener(schedulePublish);
  publish();
  Timer.periodic(const Duration(seconds: 2), (_) => publish());
  web.window.addEventListener(
    'beforeunload',
    ((web.Event event) {
      if (!webUpdateSafety.snapshot.isSafe) {
        event.preventDefault();
        (event as web.BeforeUnloadEvent).returnValue = '';
      }
    }).toJS,
  );
}
