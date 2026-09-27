import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

/// One guard registration per editor instance; pushed lookup pages keep it alive.
class FormDraftNavigation {
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
  }) {
    _guards[owner] = (
      path: Uri.parse(path).path,
      pageKey: pageKey,
      leave: leave,
    );
  }

  static void unregister(Object owner) => _guards.remove(owner);

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
