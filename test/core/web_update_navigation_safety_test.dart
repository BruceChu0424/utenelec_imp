import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/web_update/app_update_safety_host.dart';
import 'package:uten_imp/core/web_update/update_safety_navigation.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

PageRoute<void> pageRoute(String name) => PageRouteBuilder<void>(
  settings: MaterialPage<void>(name: name, child: const SizedBox()),
  pageBuilder: (_, _, _) => const SizedBox(),
);

RawDialogRoute<void> dialogRoute() =>
    RawDialogRoute<void>(pageBuilder: (_, _, _) => const SizedBox());

void main() {
  test(
    'covered business dialogs continue to block after a second dialog closes',
    () {
      final safety = WebUpdateSafetyRegistry()..setReady(true);
      final observer = UpdateSafetyNavigation(registry: safety);
      addTearDown(observer.dispose);
      addTearDown(safety.dispose);
      final page = pageRoute(RouteName.dashboard);
      final editor = dialogRoute();
      final confirmation = dialogRoute();

      observer.didPush(page, null);
      expect(safety.snapshot.safeToReload, isTrue);
      observer.didPush(editor, page);
      observer.didPush(confirmation, editor);
      expect(safety.snapshot.safeToReload, isFalse);
      observer.didPop(confirmation, editor);
      expect(safety.snapshot.safeToReload, isFalse);
      observer.didRemove(editor, page);
      expect(safety.snapshot.safeToReload, isTrue);
    },
  );

  test(
    'imperative editors stay protected while the known update page is safe',
    () {
      final safety = WebUpdateSafetyRegistry()..setReady(true);
      final observer = UpdateSafetyNavigation(registry: safety);
      addTearDown(observer.dispose);
      addTearDown(safety.dispose);
      final page = pageRoute(RouteName.dashboard);
      final unknown = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final update = MaterialPageRoute<void>(
        settings: const RouteSettings(name: '/settings/software-update'),
        builder: (_) => const SizedBox(),
      );

      observer.didPush(page, null);
      observer.didPush(unknown, page);
      expect(safety.snapshot.safeToReload, isFalse);
      observer.didReplace(oldRoute: unknown, newRoute: update);
      expect(safety.snapshot.safeToReload, isTrue);
    },
  );

  test('an unknown edit route cannot become safe merely by being idle', () {
    const path = '/unverified/editor';
    expect(canAutomaticallyUpdateRoute(path), isFalse);
    expect(canAutomaticallyUpdateRoute(RouteName.dashboard), isTrue);
    final owner = Object();
    FormDraftNavigation.register(owner, path, () async => true);
    addTearDown(() => FormDraftNavigation.unregister(owner));
    expect(canAutomaticallyUpdateRoute(path), isFalse);
  });

  test('only an explicit lifecycle probe attests to saved route state', () {
    const path = '/verified/editor';
    final owner = Object();
    var dirty = false;
    FormDraftNavigation.registerReloadSafety(
      owner,
      path,
      () => WebUpdateSafetyState(dirty: dirty),
    );
    addTearDown(() => FormDraftNavigation.unregisterReloadSafety(owner));
    expect(canAutomaticallyUpdateRoute(path), isTrue);
    expect(webUpdateSafety.snapshot.dirty, isFalse);
    dirty = true;
    expect(webUpdateSafety.snapshot.dirty, isTrue);
    FormDraftNavigation.unregister(owner);
    expect(canAutomaticallyUpdateRoute(path), isTrue);
    FormDraftNavigation.unregisterReloadSafety(owner);
    expect(canAutomaticallyUpdateRoute(path), isFalse);
  });
}
