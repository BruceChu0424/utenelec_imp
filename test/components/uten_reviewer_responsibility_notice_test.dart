import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/feedback/uten_reviewer_responsibility_notice.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'shows the current employee name and code with responsibility semantics',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await tester.pumpWidget(
          ProviderScope(
            overrides: [sessionProvider.overrideWith(_ReviewerSession.new)],
            child: const MaterialApp(
              home: Scaffold(
                body: UtenReviewerResponsibilityNotice(actionLabel: '质检'),
              ),
            ),
          ),
        );

        expect(find.text('审核员：张三（QA001）'), findsOneWidget);
        final data = tester
            .getSemantics(
              find.byKey(const Key('reviewer-responsibility-notice')),
            )
            .getSemanticsData();
        expect(data.label, contains('审核员 张三（QA001）'));
        expect(data.label, contains('记录质检责任'));
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'review confirm dialog keeps the reviewer notice above the impact message',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(360, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_ReviewerSession.new)],
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showUtenReviewerConfirmDialog(
                    context,
                    message: '审核后将写入正式库存事实。',
                  ),
                  child: const Text('打开'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('确认审核'), findsWidgets);
      expect(find.text('审核员：张三（QA001）'), findsOneWidget);
      expect(find.text('审核后将写入正式库存事实。'), findsOneWidget);
      final noticeTop = tester.getTopLeft(
        find.byKey(const Key('reviewer-responsibility-notice')),
      );
      final messageTop = tester.getTopLeft(find.text('审核后将写入正式库存事实。'));
      expect(noticeTop.dy, lessThan(messageTop.dy));
      expect(tester.takeException(), isNull);
    },
  );
}

class _ReviewerSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState(
    user: AppUser(
      id: 'reviewer-user',
      code: 'QA001',
      name: '张三',
      roles: [],
      employeeId: 'reviewer-employee',
    ),
  );
}
