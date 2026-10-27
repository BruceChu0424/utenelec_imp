import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_info.dart';
import '../network/server_config.dart';

/// Changes only the visible native caption. Installation identifiers and
/// preference/storage directory metadata remain independent and fixed.
class PlatformWindowTitleController {
  PlatformWindowTitleController({
    this.channel = const MethodChannel('com.uten.imp/window_title'),
    bool? enabled,
    bool Function(String title, String source)? isCurrent,
  }) : _enabled =
           enabled ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows),
       _isCurrent = isCurrent ?? ((_, _) => true);

  final MethodChannel channel;
  final bool _enabled;
  final bool Function(String title, String source) _isCurrent;
  bool _alive = true;
  bool _missingChannel = false;
  bool _scheduled = false;
  int _generation = 0;
  String? _title;
  String? _source;
  String? _lastSentTitle = AppInfo.externalName;
  Completer<void>? _completion;

  Future<void> update({required String title, required String source}) {
    if (!_alive || !_enabled || _missingChannel || !isValidWindowTitle(title)) {
      return Future.value();
    }
    if (_title == title && _source == source && _lastSentTitle == title) {
      return _completion?.future ?? Future.value();
    }
    // Pending calls for an older server/brand have no work left to perform.
    _completion?.completeIfPending();
    _title = title;
    _source = source;
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
    if (!_alive ||
        _missingChannel ||
        _title == _lastSentTitle ||
        !_isCurrent(_title!, _source!)) {
      completion?.completeIfPending();
      return;
    }
    final title = _title!;
    final source = _source!;
    final generation = _generation;
    _lastSentTitle = title;
    unawaited(_invoke(title, source, generation, completion!));
  }

  Future<void> _invoke(
    String title,
    String source,
    int generation,
    Completer<void> completion,
  ) async {
    try {
      // MethodChannel guarantees FIFO; Win32 applies the caption synchronously
      // before replying. Replies never trigger another write of an old title.
      await channel.invokeMethod<void>('setTitle', title);
    } on MissingPluginException {
      // A new Flutter bundle may briefly run with an older runner binary.
      if (_alive && generation == _generation && _isCurrent(title, source)) {
        _missingChannel = true;
      }
    } on PlatformException {
      // A closing window or invalid native argument is cosmetic, not an app
      // failure. Only the current request may affect future retry bookkeeping.
      if (_alive && generation == _generation && _isCurrent(title, source)) {
        _lastSentTitle = null;
      }
    } finally {
      completion.completeIfPending();
    }
  }

  void dispose() {
    _alive = false;
    _generation++;
    _completion?.completeIfPending();
  }
}

extension on Completer<void> {
  void completeIfPending() {
    if (!isCompleted) complete();
  }
}

bool isValidWindowTitle(String title) =>
    title.trim().isNotEmpty &&
    title.length <= 80 &&
    !RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(title);

final platformWindowTitleControllerProvider =
    Provider<PlatformWindowTitleController>((ref) {
      final controller = PlatformWindowTitleController(
        isCurrent: (title, source) =>
            ref.read(apiBaseUrlProvider) == source &&
            title == AppInfo.externalName,
      );
      ref.onDispose(controller.dispose);
      return controller;
    });

final platformWindowTitleSyncProvider = Provider<void>((ref) {
  const title = AppInfo.externalName;
  final source = ref.watch(apiBaseUrlProvider);
  unawaited(
    ref
        .read(platformWindowTitleControllerProvider)
        .update(title: title, source: source),
  );
});
