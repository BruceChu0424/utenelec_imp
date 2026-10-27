import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The two presentations share one native window and one Flutter engine.
enum DesktopWindowMode { login, main }

bool get supportsDesktopWindow =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

/// One entry point for Windows/AppKit window presentation and login controls.
/// Cosmetic failures must never replay login, logout, or other business work.
class DesktopWindowController {
  DesktopWindowController({
    this.channel = const MethodChannel('com.uten.imp/desktop_window'),
    bool? enabled,
  }) : enabled = enabled ?? supportsDesktopWindow;

  final MethodChannel channel;
  final bool enabled;
  bool _alive = true;
  bool _missingChannel = false;
  bool _scheduled = false;
  int _generation = 0;
  DesktopWindowMode? _desired;
  DesktopWindowMode? _lastSent;
  Completer<void>? _completion;

  Future<void> setMode(DesktopWindowMode mode) {
    if (!_alive || !enabled || _missingChannel) return Future.value();
    if (_desired == mode && _lastSent == mode) {
      return _completion?.future ?? Future.value();
    }
    _complete(_completion);
    _desired = mode;
    _generation++;
    final completion = _completion = Completer<void>();
    if (!_scheduled) {
      _scheduled = true;
      scheduleMicrotask(_dispatchLatest);
    }
    return completion.future;
  }

  void _dispatchLatest() {
    _scheduled = false;
    final completion = _completion;
    if (!_alive || _missingChannel || _desired == _lastSent) {
      _complete(completion);
      return;
    }
    final mode = _desired!;
    final generation = _generation;
    _lastSent = mode;
    // MethodChannel preserves invocation order. Both native runners apply the
    // mode before replying; late replies never restore an old presentation.
    unawaited(_sendMode(mode, generation, completion!));
  }

  Future<void> _sendMode(
    DesktopWindowMode mode,
    int generation,
    Completer<void> completion,
  ) async {
    try {
      await channel.invokeMethod<void>('setMode', mode.name);
    } on MissingPluginException {
      if (_alive && generation == _generation) _missingChannel = true;
    } on PlatformException {
      if (_alive && generation == _generation) _lastSent = null;
    } finally {
      _complete(completion);
    }
  }

  Future<void> beginDrag() => _loginAction('beginDrag');
  Future<void> minimize() => _loginAction('minimize');
  Future<void> close() => _loginAction('close');

  Future<void> _loginAction(String method) async {
    if (!_alive ||
        !enabled ||
        _missingChannel ||
        _desired != DesktopWindowMode.login) {
      return;
    }
    try {
      await channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // An older runner still has its own native title bar and close action.
    } on PlatformException {
      // A window that is already closing needs no further UI action.
    }
  }

  void dispose() {
    _alive = false;
    _generation++;
    _complete(_completion);
  }

  static void _complete(Completer<void>? completion) {
    if (completion != null && !completion.isCompleted) completion.complete();
  }
}

final desktopWindowControllerProvider = Provider<DesktopWindowController>((
  ref,
) {
  final controller = DesktopWindowController();
  ref.onDispose(controller.dispose);
  return controller;
});
