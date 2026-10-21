import 'dart:async';

import 'package:flutter/widgets.dart';

/// Collects the real list requests started when a host advances its
/// refresh tick. The host's button waits for its visible segment, without
/// inventing a timer or assuming that provider invalidation has finished I/O.
class UtenRefreshController {
  Set<Future<void>>? _requests;
  Future<void>? _inFlight;
  final _cancelled = Completer<void>();
  bool _disposed = false;

  /// Concurrent buttons share one refresh; leaving the host releases its wait.
  Future<void> run(VoidCallback trigger) {
    if (_disposed) return Future<void>.value();
    final active = _inFlight;
    if (active != null) return active;
    final completion = Completer<void>();
    final future = completion.future;
    _inFlight = future;
    _run(trigger).then<void>(
      (_) {
        if (identical(_inFlight, future)) _inFlight = null;
        completion.complete();
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_inFlight, future)) _inFlight = null;
        completion.completeError(error, stack);
      },
    );
    return future;
  }

  Future<void> _run(VoidCallback trigger) async {
    final requests = <Future<void>>{};
    _requests = requests;
    try {
      trigger();
      // didUpdateWidget and first-mount post-frame loaders register during the
      // next build. With no selected segment, the set correctly stays empty.
      await Future.any([WidgetsBinding.instance.endOfFrame, _cancelled.future]);
      var completedCount = 0;
      while (!_disposed) {
        final batch = requests.skip(completedCount).toList(growable: false);
        if (batch.isEmpty) return;
        completedCount = requests.length;
        await Future.any([Future.wait(batch), _cancelled.future]);
        if (_disposed) return;
        // Scope/permission metadata may finish first and only then mount the
        // visible list. Keep collecting through that resulting frame, and wait
        // for any new requests until one complete frame registers no more work.
        await Future.any([
          WidgetsBinding.instance.endOfFrame,
          _cancelled.future,
        ]);
      }
    } finally {
      if (identical(_requests, requests)) _requests = null;
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _requests = null;
    _cancelled.complete();
  }

  /// Registers work started directly by the host, such as scope/count reloads.
  void track(Future<void> request) {
    if (_requests == null) return;
    // A synchronously rejected loader may finish before the collection frame.
    // Mark it handled now; Future.wait still receives its original error later.
    request.ignore();
    _requests!.add(request);
  }
}

class UtenRefreshScope extends InheritedWidget {
  const UtenRefreshScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final UtenRefreshController controller;

  /// Preserves the loader's actual Future and its existing error handling.
  static Future<void> track(BuildContext context, Future<void> request) {
    context.getInheritedWidgetOfExactType<UtenRefreshScope>()?.controller.track(
      request,
    );
    return request;
  }

  @override
  bool updateShouldNotify(UtenRefreshScope oldWidget) =>
      oldWidget.controller != controller;
}

/// A visible segment can disappear while its host remains open. Its network
/// request may continue for caching/server semantics, but the old segment must
/// no longer keep the host's refresh button waiting after the user switches it.
mixin UtenRefreshParticipant<T extends StatefulWidget> on State<T> {
  final _refreshParticipantDisposed = Completer<void>();
  final _refreshReplacements = <Object, Completer<void>>{};

  /// A query that replaces an earlier result can release that obsolete wait.
  /// Other requests still run independently unless they share [replaceKey].
  Future<void> trackRefresh(Future<void> request, {Object? replaceKey}) {
    if (!mounted) {
      request.ignore();
      return Future<void>.value();
    }
    Completer<void>? replaced;
    if (replaceKey != null) {
      final previous = _refreshReplacements[replaceKey];
      if (previous != null && !previous.isCompleted) previous.complete();
      replaced = Completer<void>();
      _refreshReplacements[replaceKey] = replaced;
    }
    return UtenRefreshScope.track(
      context,
      Future.any([
        request,
        _refreshParticipantDisposed.future,
        if (replaced != null) replaced.future,
      ]),
    );
  }

  @override
  void dispose() {
    _refreshParticipantDisposed.complete();
    _refreshReplacements.clear();
    super.dispose();
  }
}
