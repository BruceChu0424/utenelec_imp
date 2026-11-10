import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/feedback/uten_reviewer_responsibility_notice.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets(
    'boxed responsibility uses the same adjacent hint as inline identity',
    (tester) async {
      const detail = '当前审核员承担本次放行责任';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_ReviewerSession.new)],
          child: const MaterialApp(
            home: Scaffold(
              body: UtenReviewerResponsibilityNotice(
                actionLabel: '财务确认',
                description: detail,
              ),
            ),
          ),
        ),
      );
      expect(find.text('审核员：张三(QA001)'), findsOneWidget);
      expect(find.text(detail), findsNothing);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text(detail), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'inline reviewer identity stays beside its title with accessible responsibility disclosure at large text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const description = '逐项核对原件后承担本次审批责任';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sessionProvider.overrideWith(_ReviewerSession.new)],
          child: MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: Padding(
                padding: EdgeInsets.all(12),
                child: Row(
                  children: [
                    Text('审批意见'),
                    Flexible(
                      child: UtenReviewerResponsibilityNotice(
                        actionLabel: '报销审批',
                        inline: true,
                        description: description,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('审核员：张三(QA001)'), findsOneWidget);
      expect(find.text(description), findsNothing);
      expect(find.byType(UtenFieldHintIcon), findsOneWidget);
      final title = tester.getRect(find.text('审批意见'));
      final identity = tester.getRect(find.text('审核员：张三(QA001)'));
      expect(identity.left, greaterThanOrEqualTo(title.right));
      expect(identity.right, lessThanOrEqualTo(348.1));
      await tester.tap(find.byType(UtenFieldHintIcon));
      await tester.pumpAndSettle();
      expect(find.text(description), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

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

        expect(find.text('审核员：张三(QA001)'), findsOneWidget);
        final data = tester
            .getSemantics(
              find.byKey(const Key('reviewer-responsibility-notice')),
            )
            .getSemanticsData();
        expect(data.label, contains('审核员 张三(QA001)'));
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
      expect(find.text('审核员：张三(QA001)'), findsOneWidget);
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
      employeeId: 'reviewer-employee',
    ),
  );
}
