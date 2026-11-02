@TestOn('browser')
library;

import 'dart:async';
import 'dart:js_interop';

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/web_update/web_update_bridge.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';

@JS('window.utenWebUpdatePrepare')
external JSPromise<JSBoolean> _prepare();

@JS('window.utenWebUpdateSafety')
external JSObject get _safety;

@JS('window.utenWebServerMaintenance')
external JSObject get _maintenance;

@JS('window.utenWebServerReloadAuthorized')
external set _authorized(JSBoolean value);

void main() {
  test(
    'real browser bridge awaits storage, publishes maintenance and scopes unload authorization',
    () async {
      installWebUpdateSafetyBridge();
      webUpdateSafety.setReady(true);
      final owner = Object();
      addTearDown(() {
        webUpdateSafety.unregister(owner);
        _authorized = false.toJS;
      });
      var saved = false;
      final commit = Completer<void>();
      webUpdateSafety.register(
        owner,
        () => WebUpdateSafetyState(dirty: true, serverReloadOverride: saved),
      );
      webUpdateSafety.registerServerReloadCheckpoint(owner, () async {
        await commit.future;
        saved = true;
      });
      var finished = false;
      final preparation = _prepare().toDart.then((value) {
        finished = true;
        return value.toDart;
      });
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      commit.complete();
      expect(await preparation, isTrue);
      expect((_safety.dartify() as Map)['serverReloadSafe'], isTrue);
      final ordinaryLeave = web.Event(
        'beforeunload',
        web.EventInit(cancelable: true),
      );
      web.window.dispatchEvent(ordinaryLeave);
      expect(ordinaryLeave.defaultPrevented, isTrue);
      _authorized = true.toJS;
      final serverLeave = web.Event(
        'beforeunload',
        web.EventInit(cancelable: true),
      );
      web.window.dispatchEvent(serverLeave);
      expect(serverLeave.defaultPrevented, isFalse);
      saved = false;
      final changedDuringLeave = web.Event(
        'beforeunload',
        web.EventInit(cancelable: true),
      );
      web.window.dispatchEvent(changedDuringLeave);
      expect(changedDuringLeave.defaultPrevented, isTrue);

      publishWebServerMaintenance('updating', 'notice-1');
      expect((_maintenance.dartify() as Map)['state'], 'updating');
      expect((_maintenance.dartify() as Map)['noticeKey'], 'notice-1');
    },
  );
}
