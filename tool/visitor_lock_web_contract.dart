// Synthetic browser-only contract. No credentials or company endpoints.
import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
import 'package:uten_imp/core/security/auth_refresh_lock.dart';

@JS('Object.getPrototypeOf')
external JSObject _prototype(JSObject object);
@JS('Reflect.deleteProperty')
external bool _delete(JSObject object, JSString key);

void send(String event) =>
    web.window.parent!.postMessage(event.toJS, web.window.location.origin.toJS);

Future<void> main() async {
  final role = Uri.base.queryParameters['role'];
  const scope = 'visitor-synthetic-two-context-contract';
  const marker = 'uten.test.visitor-lock-owner';
  if (role == 'holder') {
    final release = Completer<void>();
    web.window.addEventListener(
      'message',
      ((web.MessageEvent event) {
        if ((event.data as JSString).toDart == 'release' &&
            !release.isCompleted) {
          release.complete();
        }
      }).toJS,
    );
    await AuthRefreshLock.runScoped(scope, () async {
      web.window.localStorage.setItem(marker, 'holder');
      send('holder-entered');
      await release.future;
      web.window.localStorage.removeItem(marker);
    }, requireWebLocks: true);
    send('holder-left');
    return;
  }
  if (role == 'competitor') {
    send('competitor-started');
    await AuthRefreshLock.runScoped(scope, () async {
      send(
        web.window.localStorage.getItem(marker) == null
            ? 'competitor-entered'
            : 'overlap',
      );
    }, requireWebLocks: true);
    return;
  }
  if (role == 'unsupported') {
    // Navigator prototypes belong to this iframe; other contexts keep Web Locks.
    _delete(_prototype(web.window.navigator), 'locks'.toJS);
    var entered = false;
    try {
      await AuthRefreshLock.runScoped(
        'visitor-synthetic-unsupported',
        () async {
          entered = true;
        },
        requireWebLocks: true,
      );
      send('unsupported-entered');
    } on UnsupportedError {
      send(entered ? 'unsupported-entered' : 'unsupported-fails-closed');
    }
    return;
  }

  final events = <String>[];
  var released = false;
  web.HTMLIFrameElement frame(String role) {
    final iframe = web.HTMLIFrameElement()..src = 'index.html?role=$role';
    web.document.body!.appendChild(iframe);
    return iframe;
  }

  late web.HTMLIFrameElement holder;
  void finish(bool passed) {
    web.document.body!.textContent = jsonEncode({
      'passed': passed,
      'events': events,
      'mechanism':
          'actual Chrome Web Locks across separate same-origin iframe isolates',
      'businessRequests': 0,
    });
    web.window.localStorage.removeItem(marker);
  }

  web.window.addEventListener(
    'message',
    ((web.MessageEvent event) {
      final value = (event.data as JSString).toDart;
      events.add(value);
      switch (value) {
        case 'holder-entered':
          frame('competitor');
        case 'competitor-started':
          Timer(const Duration(milliseconds: 150), () {
            released = true;
            holder.contentWindow!.postMessage(
              'release'.toJS,
              web.window.location.origin.toJS,
            );
          });
        case 'competitor-entered':
          if (!released) {
            finish(false);
            return;
          }
          frame('unsupported');
        case 'unsupported-fails-closed':
          finish(true);
        case 'overlap' || 'unsupported-entered':
          finish(false);
      }
    }).toJS,
  );
  web.document.body!.textContent = 'Running isolated Web Locks contract';
  holder = frame('holder');
}
