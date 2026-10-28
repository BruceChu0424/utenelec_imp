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

/// One entry point for Windows/AppKit window presentation and shared controls.
/// Cosmetic failures must never replay login, logout, or other business work.
class DesktopWindowController {
  DesktopWindowController({
    this.channel = const MethodChannel('com.uten.imp/desktop_window'),
    bool? enabled,
  }) : enabled = enabled ?? supportsDesktopWindow {
    if (this.enabled) channel.setMethodCallHandler(_onWindowMethodCall);
  }

  final MethodChannel channel;
  final bool enabled;
  final _maximized = ValueNotifier(false);
  ValueListenable<bool> get maximized => _maximized;
  bool _alive = true;
  bool _missingChannel = false;
  bool _scheduled = false;
  int _generation = 0;
  int _windowStateRevision = 0;
  bool _toggleInFlight = false;
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
    if (mode == DesktopWindowMode.login) _updateMaximized(false);
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
      if (mode == DesktopWindowMode.main) {
        await _refreshWindowState(generation);
      }
    } on MissingPluginException {
      if (_alive && generation == _generation) _missingChannel = true;
    } on PlatformException {
      if (_alive && generation == _generation) _lastSent = null;
    } finally {
      _complete(completion);
    }
  }

  Future<void> beginDrag() => _windowAction('beginDrag');
  Future<void> minimize() => _windowAction('minimize');
  Future<void> close() => _windowAction('close');

  Future<void> toggleMaximize() async {
    if (_toggleInFlight || _desired != DesktopWindowMode.main) return;
    _toggleInFlight = true;
    final generation = _generation;
    try {
      await _windowAction('toggleMaximize');
      await _refreshWindowState(generation);
    } finally {
      _toggleInFlight = false;
    }
  }

  Future<void> _windowAction(String method) async {
    if (!_alive || !enabled || _missingChannel || _desired == null) {
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

  Future<dynamic> _onWindowMethodCall(MethodCall call) async {
    if (_alive &&
        call.method == 'windowStateChanged' &&
        _desired == DesktopWindowMode.main) {
      final arguments = call.arguments;
      if (arguments is Map && arguments['maximized'] is bool) {
        _updateMaximized(arguments['maximized'] as bool);
      }
    }
    return null;
  }

  Future<void> _refreshWindowState(int generation) async {
    if (!_alive ||
        !enabled ||
        _missingChannel ||
        generation != _generation ||
        _desired != DesktopWindowMode.main) {
      return;
    }
    final revision = _windowStateRevision;
    try {
      final state = await channel.invokeMapMethod<String, dynamic>(
        'getWindowState',
      );
      if (_alive &&
          generation == _generation &&
          _desired == DesktopWindowMode.main &&
          revision == _windowStateRevision &&
          state?['maximized'] is bool) {
        _updateMaximized(state!['maximized'] as bool);
      }
    } on MissingPluginException {
      // Older runners can still perform supported window actions.
    } on PlatformException {
      // A later native window event will refresh the presentation.
    }
  }

  void _updateMaximized(bool value) {
    _windowStateRevision++;
    if (_alive) _maximized.value = value;
  }

  void dispose() {
    if (!_alive) return;
    _alive = false;
    _generation++;
    _complete(_completion);
    if (enabled) channel.setMethodCallHandler(null);
    _maximized.dispose();
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
