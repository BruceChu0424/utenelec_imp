import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_update_safety.dart';

@JS('window.utenWebUpdateSafety')
external set _publishedSafety(JSObject value);

@JS('window.utenWebUpdateSafetyProbe')
external set _safetyProbe(JSFunction value);

@JS('window.utenWebUpdatePrepare')
external set _prepareReload(JSFunction value);

@JS('window.utenWebServerReloadAuthorized')
external JSBoolean? get _serverReloadAuthorized;

@JS('window.utenWebServerReloadAuthorized')
external set _serverReloadAuthorized(JSBoolean? value);

@JS('window.utenWebServerMaintenance')
external set _maintenance(JSObject value);

/// Reuses the application's single maintenance/readiness loop on every route.
void publishWebServerMaintenance(String phase, String noticeKey) {
  final value =
      {
            'schemaVersion': 1,
            'state': phase,
            'noticeKey': noticeKey,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          }.jsify()
          as JSObject;
  _maintenance = value;
  web.window.dispatchEvent(web.CustomEvent('uten:web-server-maintenance'));
}

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
  _prepareReload = (() => (() async {
    final ready = await webUpdateSafety.prepareServerReload();
    publish();
    return ready.toJS;
  })().toJS).toJS;
  webUpdateSafety.addListener(schedulePublish);
  publish();
  Timer.periodic(const Duration(seconds: 2), (_) => publish());
  web.window.addEventListener(
    'beforeunload',
    ((web.Event event) {
      final authorized =
          _serverReloadAuthorized?.toDart == true &&
          webUpdateSafety.snapshot.serverReloadSafe;
      // Authorization belongs to this navigation attempt only. A cancelled
      // departure must not disable protection for a later manual close.
      _serverReloadAuthorized = false.toJS;
      if (!authorized && !webUpdateSafety.snapshot.isSafe) {
        event.preventDefault();
        (event as web.BeforeUnloadEvent).returnValue = '';
      }
    }).toJS,
  );
}
