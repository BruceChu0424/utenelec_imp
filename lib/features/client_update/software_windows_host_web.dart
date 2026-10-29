import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'software_host_info.dart';

String? softwareWindowsUserAgent() => web.window.navigator.userAgent;

@JS()
extension type _HostNavigator(JSObject _) implements JSObject {
  external _HostUaData? get userAgentData;
}

@JS()
extension type _HostUaData(JSObject _) implements JSObject {
  external JSString? get platform;
  external JSPromise<JSObject> getHighEntropyValues(JSArray<JSString> hints);
}

Future<SoftwareHostInfo> readSoftwareHostInfo() async {
  final navigator = web.window.navigator;
  Map<String, Object?>? hints;
  try {
    final data = _HostNavigator(navigator).userAgentData;
    if (data != null) {
      final high = await data
          .getHighEntropyValues(
            [
              'architecture'.toJS,
              'bitness'.toJS,
              'platformVersion'.toJS,
              'wow64'.toJS,
            ].toJS,
          )
          .toDart
          .timeout(const Duration(milliseconds: 1200));
      hints = {
        'platform': data.platform?.toDart,
        for (final name in ['architecture', 'bitness', 'platformVersion'])
          name: (high.getProperty<JSAny?>(name.toJS))?.dartify(),
        'wow64': (high.getProperty<JSAny?>('wow64'.toJS))?.dartify(),
      };
    }
  } catch (_) {
    // Firefox, older Chromium and permissions-policy denial use cautious UA hints.
  }
  return softwareHostFromBrowser(
    userAgent: navigator.userAgent,
    navigatorPlatform: navigator.platform,
    maxTouchPoints: navigator.maxTouchPoints,
    clientHints: hints,
  );
}
