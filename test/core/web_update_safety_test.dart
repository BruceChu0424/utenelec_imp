import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

void main() {
  test(
    'build-time notifications are deferred and repeated equal reports do not loop',
    () async {
      final safety = WebUpdateSafetyRegistry();
      addTearDown(safety.dispose);
      var notifications = 0;
      safety.addListener(() {
        notifications++;
        safety.changed();
      });
      safety.setReady(true);
      expect(notifications, 0);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      safety.changed();
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
    },
  );

  test(
    'a navigation reset cannot remove the editor lifecycle safety probe',
    () {
      final owner = Object();
      FormDraftNavigation.registerReloadSafety(
        owner,
        '/editor',
        () => const WebUpdateSafetyState(dirty: true),
      );
      FormDraftNavigation.register(
        owner,
        '/editor',
        () async => true,
        reloadSafety: () => const WebUpdateSafetyState(),
      );
      FormDraftNavigation.unregister(owner);
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isTrue);
      expect(webUpdateSafety.snapshot.dirty, isTrue);
      FormDraftNavigation.unregisterReloadSafety(owner);
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isFalse);
    },
  );

  test(
    'initial readiness, dirty, busy and unknown independently prevent reload',
    () {
      final safety = WebUpdateSafetyRegistry();
      addTearDown(safety.dispose);
      expect(safety.snapshot.safeToReload, isFalse);
      safety.setReady(true);
      expect(safety.snapshot.safeToReload, isTrue);
      final editor = Object(), request = Object(), unknown = Object();
      safety.register(editor, () => const WebUpdateSafetyState(dirty: true));
      safety.register(request, () => const WebUpdateSafetyState(busy: true));
      safety.register(unknown, () => const WebUpdateSafetyState(blocked: true));
      expect(safety.snapshot.dirty, isTrue);
      expect(safety.snapshot.busy, isTrue);
      expect(safety.snapshot.blocked, isTrue);
      safety.unregister(editor);
      expect(safety.snapshot.safeToReload, isFalse);
      safety.unregister(request);
      expect(safety.snapshot.safeToReload, isFalse);
      safety.unregister(unknown);
      expect(safety.snapshot.safeToReload, isTrue);
    },
  );

  test(
    'a broken inspector blocks reload and snapshots reveal only safe metadata',
    () {
      final safety = WebUpdateSafetyRegistry()..setReady(true);
      addTearDown(safety.dispose);
      safety.register(
        Object(),
        () => throw StateError('private editor content'),
      );
      final snapshot = safety.snapshot;
      expect(snapshot.blocked, isTrue);
      expect(snapshot.safeToReload, isFalse);
      expect(snapshot.toJson(now: DateTime.fromMillisecondsSinceEpoch(42)), {
        'schemaVersion': 1,
        'ready': true,
        'dirty': false,
        'busy': false,
        'blocked': true,
        'updatedAt': 42,
      });
    },
  );

  test(
    'legacy leave guards stay unknown and safety reads never run dialogs',
    () {
      final owner = Object();
      var leaveCalls = 0;
      FormDraftNavigation.register(owner, '/editor?tab=lines', () async {
        leaveCalls++;
        return true;
      });
      addTearDown(() => FormDraftNavigation.unregister(owner));
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isFalse);
      expect(webUpdateSafety.snapshot.blocked, isTrue);
      FormDraftNavigation.register(
        owner,
        '/editor?tab=lines',
        () async {
          leaveCalls++;
          return true;
        },
        reloadSafety: () => const WebUpdateSafetyState(dirty: true),
      );
      expect(
        FormDraftNavigation.hasReloadSafetyForPath('/editor?tab=basic'),
        isTrue,
      );
      expect(FormDraftNavigation.hasReloadSafetyForPath('/other'), isFalse);
      expect(webUpdateSafety.snapshot.dirty, isTrue);
      expect(leaveCalls, 0);
      FormDraftNavigation.unregister(owner);
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isFalse);
    },
  );
}
