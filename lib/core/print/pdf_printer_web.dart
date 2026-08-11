import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

const _cleanupDelay = Duration(minutes: 1);
const _loadTimeout = Duration(seconds: 15);

Future<bool> printPdfBytes(Uint8List bytes, String filename) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);

  if (_isMobileBrowser || web.document.body == null) {
    _download(url, filename);
    return true;
  }

  final frame = web.HTMLIFrameElement()..src = url;
  frame.setAttribute('hidden', '');
  final completer = Completer<bool>();
  Timer? timeout;

  void cleanup() {
    frame.remove();
    web.URL.revokeObjectURL(url);
  }

  late web.EventListener onLoad;
  onLoad = (web.Event _) {
    frame.removeEventListener('load', onLoad);
    timeout?.cancel();
    try {
      final contentWindow = frame.contentWindow;
      if (contentWindow == null) {
        _download(url, filename);
      } else {
        contentWindow.focus();
        contentWindow.print();
      }
      if (!completer.isCompleted) completer.complete(true);
    } catch (_) {
      _download(url, filename);
      if (!completer.isCompleted) completer.complete(true);
    } finally {
      Timer(_cleanupDelay, cleanup);
    }
  }.toJS;

  frame.addEventListener('load', onLoad);
  web.document.body!.append(frame);
  timeout = Timer(_loadTimeout, () {
    frame.removeEventListener('load', onLoad);
    _download(url, filename);
    if (!completer.isCompleted) completer.complete(true);
    Timer(_cleanupDelay, cleanup);
  });
  return completer.future;
}

bool get _isMobileBrowser {
  final userAgent = web.window.navigator.userAgent.toLowerCase();
  return userAgent.contains('android') ||
      userAgent.contains('iphone') ||
      userAgent.contains('ipad') ||
      userAgent.contains('mobile');
}

void _download(String url, String filename) {
  final anchor = web.HTMLAnchorElement()
    ..href = url
    ..download = filename;
  web.document.body?.append(anchor);
  anchor.click();
  anchor.remove();
}
