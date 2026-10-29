import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/core/web_update/web_update_safety.dart';
import 'package:uten_imp/features/basic_data/widgets/master_inline_edit.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

typedef _Row = ({String id, String name});

void main() {
  testWidgets(
    'imperative inline editor protects edits and pending saves until receipt',
    (tester) async {
      webUpdateSafety.setReady(true);
      final controller = MasterInlineEditController<_Row>()..begin();
      await tester.pumpWidget(
        MaterialApp(
          home: MasterInlineEditGuard<_Row>(
            controller: controller,
            authorityKey: 'owner',
            child: const SizedBox(),
          ),
        ),
      );
      await tester.pump();
      expect(webUpdateSafety.snapshot.isSafe, isTrue);
      final field = MasterInlineField<_Row>(
        key: 'name',
        read: (row) => row.name,
      );
      controller.setValue('one', field, 'edited', originalValue: 'before');
      expect(webUpdateSafety.snapshot.dirty, isTrue);
      final started = Completer<void>(), response = Completer<void>();
      final save = controller.save((id, patch) {
        started.complete();
        return response.future;
      });
      await started.future;
      expect(webUpdateSafety.snapshot.busy, isTrue);
      expect(webUpdateSafety.snapshot.isSafe, isFalse);
      response.complete();
      expect(await save, isTrue);
      await tester.pump();
      expect(webUpdateSafety.snapshot.isSafe, isTrue);
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await tester.pump();
      expect(webUpdateSafety.snapshot.isSafe, isTrue);
    },
  );

  testWidgets(
    'clean inline list attests its route for its complete mounted lifetime',
    (tester) async {
      webUpdateSafety.setReady(true);
      final controller = MasterInlineEditController<_Row>();
      final router = GoRouter(
        initialLocation: '/editor',
        routes: [
          GoRoute(
            path: '/editor',
            builder: (_, _) => MasterInlineEditGuard<_Row>(
              controller: controller,
              authorityKey: 'owner',
              child: const SizedBox(),
            ),
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(controller.dirty, isFalse);
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isTrue);
      expect(webUpdateSafety.snapshot.isSafe, isTrue);
      await tester.pumpWidget(const SizedBox());
      router.dispose();
      controller.dispose();
      await tester.pump();
      expect(FormDraftNavigation.hasReloadSafetyForPath('/editor'), isFalse);
      expect(webUpdateSafety.snapshot.isSafe, isTrue);
    },
  );
}
