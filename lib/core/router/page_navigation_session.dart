import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'page_search_lifecycle.dart';

/// Owns child-page visits for one mounted page or panel.
///
/// Attach from the owner's didChangeDependencies and dispose with that State.
/// Normal pop preserves its typed result. Browser/go returns can leave the
/// router's original push Future pending; returning to the owning page ends
/// that visit with null instead. Replacing an editor with its detail page does
/// not end the visit while the owner is still covered.
///
/// Disposal also ends pending visits with null. Callers must check mounted and
/// their business/identity generation before updating data after awaiting a
/// visit, just as they must after any asynchronous navigation or dialog.
class PageNavigationSession {
  final Set<Completer<void>> _visits = {};
  late final _lifecycle = PageSearchLifecycle(
    onLeave: () {
      _departedWithVisit = _visits.isNotEmpty;
      _returnedVisit = false;
    },
    onReturn: () {
      _returnedVisit = _departedWithVisit;
      _departedWithVisit = false;
      _completeVisits();
    },
  );
  BuildContext? _context;
  bool _disposed = false;
  bool _departedWithVisit = false;
  bool _returnedVisit = false;

  /// Lets an existing page-resume refresh yield once to the visit's own refresh.
  ///
  /// Use only when the caller refreshes after awaiting [push]. A later return
  /// from a link outside this session must still perform its normal refresh.
  bool consumeReturnedVisit() {
    final returned = _returnedVisit;
    _returnedVisit = false;
    return returned;
  }

  void attach(BuildContext context) {
    if (_disposed) return;
    _context = context;
    _lifecycle.attach(context, fallbackToActivePage: true);
  }

  Future<T?> push<T extends Object?>(String location, {Object? extra}) async {
    if (_disposed) return null;
    final context = _context;
    if (context == null) {
      throw StateError('Attach PageNavigationSession before opening a page.');
    }
    if (!context.mounted) return null;
    final visit = Completer<void>();
    _visits.add(visit);
    try {
      return await Future.any<T?>([
        context.push<T>(location, extra: extra),
        visit.future.then<T?>((_) => null),
      ]);
    } finally {
      _visits.remove(visit);
    }
  }

  void _completeVisits() {
    // A resumed caller can open a new child later. Finish only visits that
    // existed at this return, never a later visit or a business write lock.
    for (final visit in _visits.toList(growable: false)) {
      if (!visit.isCompleted) visit.complete();
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _lifecycle.dispose();
    _completeVisits();
    _context = null;
  }
}
