import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../core/web_update/web_update_safety.dart';

/// One guard registration per editor instance; pushed lookup pages keep it alive.
class FormDraftNavigation {
  static final _reloadSafetyPaths = <Object, String>{};
  static final _guardSafetyOwners = <Object, Object>{};
  static final _guards =
      <
        Object,
        ({
          String path,
          ValueKey<String>? pageKey,
          Future<bool> Function() leave,
        })
      >{};

  static void register(
    Object owner,
    String path,
    Future<bool> Function() leave, {
    ValueKey<String>? pageKey,
    WebUpdateSafetyState Function()? reloadSafety,
  }) {
    _guards[owner] = (
      path: Uri.parse(path).path,
      pageKey: pageKey,
      leave: leave,
    );
    final safetyOwner = _guardSafetyOwners.putIfAbsent(owner, Object.new);
    if (reloadSafety == null) {
      _reloadSafetyPaths.remove(safetyOwner);
      webUpdateSafety.register(safetyOwner, _unknownReloadSafety);
    } else {
      registerReloadSafety(safetyOwner, path, reloadSafety);
    }
  }

  static WebUpdateSafetyState _unknownReloadSafety() =>
      const WebUpdateSafetyState(blocked: true);

  static bool hasReloadSafetyForPath(String path) {
    final normalized = Uri.parse(path).path;
    return _reloadSafetyPaths.values.contains(normalized);
  }

  static void registerReloadSafety(
    Object owner,
    String path,
    WebUpdateSafetyState Function() probe,
  ) {
    _reloadSafetyPaths[owner] = Uri.parse(path).path;
    webUpdateSafety.register(owner, probe);
  }

  static void unregisterReloadSafety(Object owner) {
    _reloadSafetyPaths.remove(owner);
    webUpdateSafety.unregister(owner);
  }

  static void unregister(Object owner) {
    _guards.remove(owner);
    final safetyOwner = _guardSafetyOwners.remove(owner);
    if (safetyOwner != null) unregisterReloadSafety(safetyOwner);
  }

  static Future<bool> onExit(BuildContext context, GoRouterState state) async {
    final guards = _guards.values
        .where(
          (guard) => guard.pageKey != null
              ? guard.pageKey == state.pageKey
              : guard.path == state.uri.path,
        )
        .toList()
        .reversed;
    for (final guard in guards) {
      if (!await guard.leave()) return false;
    }
    return true;
  }
}

/// Use for every concrete route, so new modules inherit leave protection.
/// Redirect-only routes have no editor and therefore need no exit callback.
class DraftAwareGoRoute extends GoRoute {
  DraftAwareGoRoute({
    required super.path,
    super.name,
    super.builder,
    super.pageBuilder,
    super.parentNavigatorKey,
    super.redirect,
    super.routes,
  }) : super(
         onExit: builder != null || pageBuilder != null
             ? FormDraftNavigation.onExit
             : null,
       );
}
