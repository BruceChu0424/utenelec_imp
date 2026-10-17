// Multi-target claim lifecycle. Financial decisions opt into strict ownership;
// ordinary collision hints retain their existing non-blocking default.
import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/foundation.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/human_error_message.dart';
import '../models/task_claim_view.dart';
import '../repositories/task_claim_repository.dart';

class TaskClaimSession extends ChangeNotifier {
  TaskClaimSession(
    this._repo, {
    Duration? heartbeatInterval,
    this.strict = false,
    bool Function()? isCurrentSession,
    AppLocalizations? localizations,
  }) : _interval = heartbeatInterval ?? const Duration(seconds: 30),
       _l10n = localizations ?? lookupAppLocalizations(const Locale('zh')),
       _isCurrentSession = isCurrentSession ?? (() => true);

  final TaskClaimRepository _repo;
  final Duration _interval;
  final bool strict;
  final AppLocalizations _l10n;
  final bool Function() _isCurrentSession;
  final List<_HeldClaim> _held = [];
  Timer? _timer;
  Future<bool>? _renewal;
  int _generation = 0;
  int _requested = 0;
  bool _closed = false;
  bool _blocked = false;
  String? blockedByName;
  String? failureMessage;

  bool get isCurrent => !_closed && _sameSession();
  bool _sameSession() {
    try {
      return _isCurrentSession();
    } on Object {
      return false;
    }
  }

  bool get isReady =>
      isCurrent &&
      !_blocked &&
      (!strict ||
          (_requested > 0 &&
              _held.length == _requested &&
              _held.every(
                (claim) => claim.view.leaseUntil.isAfter(DateTime.now()),
              )));
  bool get blocked => strict ? !isReady : _blocked;

  String? claimIdFor(String type, String key) {
    if (!isReady) return null;
    for (final claim in _held) {
      if (claim.type == type && claim.key == key) return claim.view.claimId;
    }
    return null;
  }

  bool _current(int generation) => isCurrent && generation == _generation;

  Future<void> claimAll(String targetType, Iterable<String> keys) async {
    if (_closed) return;
    final generation = ++_generation;
    final targets = keys.toSet().toList()..sort();
    _timer?.cancel();
    _requested += targets.length;
    _blocked = strict || _blocked;
    failureMessage = strict ? _l10n.taskClaimChecking : null;
    notifyListeners();
    for (final key in targets) {
      if (!_current(generation)) {
        _fail(_l10n.taskClaimIdentityChanged);
        return;
      }
      TaskClaimView? view;
      try {
        view = strict
            ? await _repo.claimRequired(targetType, key)
            : await _repo.claim(targetType, key);
      } on Object catch (error) {
        if (_current(generation)) {
          _fail(_failureMessage(error, _l10n.taskClaimAcquireFailed));
        }
        return;
      }
      if (!_current(generation)) {
        if (_closed && _sameSession() && view?.claimedByMe == true) {
          if (strict && view!.claimId != null) {
            await _repo.releaseRequired(
              targetType,
              key,
              expectedClaimId: view.claimId!,
            );
          } else if (!strict) {
            await _repo.release(targetType, key);
          }
        }
        return;
      }
      if (view == null) {
        if (strict) {
          _fail(_l10n.taskClaimInvalidResponse);
          return;
        }
        continue;
      }
      if (_valid(view, targetType, key)) {
        _held.add(_HeldClaim(targetType, key, view));
      } else {
        blockedByName = view.claimedByMe ? null : view.claimedByName;
        _fail(
          blockedByName == null
              ? _l10n.taskClaimExpired
              : _l10n.taskClaimTakenBy(blockedByName!),
        );
        if (strict) return;
      }
    }
    if (!_current(generation)) return;
    if (strict) _blocked = _held.length != _requested;
    failureMessage = _blocked ? failureMessage : null;
    if (_held.isNotEmpty) {
      _timer = Timer.periodic(_interval, (_) {
        if (strict) {
          validateForDecision().ignore();
        } else {
          for (final claim in _held) {
            _repo.heartbeat(claim.type, claim.key);
          }
        }
      });
    }
    notifyListeners();
  }

  /// Verify live ownership/permission; never silently reacquire a lost lease.
  /// Callers must submit the business version originally shown to the reviewer.
  Future<bool> validateForDecision() {
    if (!strict) return Future.value(!_blocked && !_closed);
    if (!isReady) {
      _fail(
        !isCurrent
            ? _l10n.taskClaimIdentityChanged
            : failureMessage ?? _l10n.taskClaimDecisionNotReady,
      );
      return Future.value(false);
    }
    return _renewal ??= _renewAll().whenComplete(() => _renewal = null);
  }

  Future<bool> _renewAll() async {
    final generation = _generation;
    for (final claim in List<_HeldClaim>.of(_held)) {
      try {
        final view = await _repo.heartbeatRequired(
          claim.type,
          claim.key,
          expectedClaimId: claim.view.claimId!,
        );
        if (!_current(generation)) return false;
        if (view == null ||
            !_valid(view, claim.type, claim.key) ||
            view.claimId != claim.view.claimId ||
            view.claimedBy != claim.view.claimedBy) {
          _fail(_l10n.taskClaimReplaced);
          return false;
        }
        claim.view = view;
      } on Object catch (error) {
        if (_current(generation)) {
          _fail(_failureMessage(error, _l10n.taskClaimRenewFailed));
        }
        return false;
      }
    }
    return _current(generation) && isReady;
  }

  String _failureMessage(Object error, String fallback) {
    if (error is! ApiException) return humanErrorMessage(error) ?? fallback;
    // A server rejection explains the actual permission, document or collision
    // guard. Keep it instead of guessing that every failure is a network issue.
    if (error.hasResponseCode && error.message.trim().isNotEmpty) {
      return error.message.trim();
    }
    if (error.code == 'NETWORK') return _l10n.taskClaimNetworkUnavailable;
    if (error.code == 'NETWORK_TIMEOUT') return _l10n.taskClaimNetworkTimeout;
    if (error.message.trim().isNotEmpty) return error.message.trim();
    return switch (error.code) {
      'UNAUTHORIZED' => _l10n.taskClaimLoginExpired,
      'FORBIDDEN' => _l10n.taskClaimPermissionDenied,
      'CONFLICT' => _l10n.taskClaimConflict,
      'NOT_FOUND' => _l10n.taskClaimNotFound,
      'RATE_LIMITED' => _l10n.taskClaimRateLimited,
      'INTERNAL' => _l10n.taskClaimServerUnavailable,
      _ => fallback,
    };
  }

  bool _valid(TaskClaimView view, String type, String key) =>
      view.claimedByMe &&
      (!strict ||
          (view.targetType == type &&
              view.targetKey == key &&
              view.claimedBy.isNotEmpty &&
              view.claimId?.isNotEmpty == true &&
              view.claimedAt.millisecondsSinceEpoch > 0 &&
              view.leaseUntil.isAfter(view.claimedAt) &&
              view.leaseUntil.isAfter(DateTime.now())));

  void _fail(String message) {
    if (_closed) return;
    _blocked = true;
    failureMessage = message;
    _timer?.cancel();
    notifyListeners();
  }

  /// Invalidate every in-flight callback before network cleanup.
  Future<void> releaseAll() async {
    if (_closed) return;
    _closed = true;
    ++_generation;
    _timer?.cancel();
    _timer = null;
    final claims = List<_HeldClaim>.of(_held);
    _held.clear();
    for (final claim in claims) {
      if (!_sameSession()) return;
      if (strict) {
        await _repo.releaseRequired(
          claim.type,
          claim.key,
          expectedClaimId: claim.view.claimId!,
        );
      } else {
        await _repo.release(claim.type, claim.key);
      }
    }
  }
}

class _HeldClaim {
  _HeldClaim(this.type, this.key, this.view);
  final String type;
  final String key;
  TaskClaimView view;
}
