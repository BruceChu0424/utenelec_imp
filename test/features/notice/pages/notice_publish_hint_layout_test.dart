import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/click_guard.dart';
import 'package:uten_imp/components/inputs/uten_field_hint_icon.dart';
import 'package:uten_imp/components/layout/uten_section_header.dart';
import 'package:uten_imp/components/layout/uten_segment_row.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_publish_page.dart';
import 'package:uten_imp/features/notice/widgets/notice_type_picker.dart';

import '../../../support/ai_launcher_page_fixture.dart';

void main() {
  for (final size in const [Size(390, 844), Size(1366, 650), Size(1920, 950)]) {
    testWidgets(
      'publish guidance is inline and actions stay reachable at $size',
      (tester) async {
        final fixture = await AiLauncherPageFixture.pump(
          tester,
          page: const NoticePublishPage(),
          route: '/notice/publish',
          size: size,
        );
        try {
          const normal = '普通通知只进入消息中心，不会产生待办任务。';
          const acknowledgment =
              '公告/制度/系统/紧急/福利 类型要求接收人登录打卡确认'
              '（未打卡每次登录都会弹窗提醒）；任务/审批/流程类只提醒。';
          final contentHeader = find.byWidgetPredicate(
            (widget) =>
                widget is UtenSectionHeader &&
                (widget.info?.contains(normal) ?? false),
          );
          expect(contentHeader, findsOneWidget);
          expect(find.text(normal), findsNothing);
          expect(find.text(acknowledgment), findsNothing);
          final hint = find.descendant(
            of: contentHeader,
            matching: find.byType(UtenFieldHintIcon),
          );
          await tester.tap(hint);
          await tester.pump();
          expect(find.text('$normal\n\n$acknowledgment'), findsOneWidget);
          Tooltip.dismissAllToolTips();
          await tester.pumpAndSettle();

          final launcher = tester.getRect(
            find.byKey(const ValueKey('ai-chat-launcher')),
          );
          for (final action in ['取消', '发布']) {
            final button = find.widgetWithText(UtenActionButton, action);
            final rect = tester.getRect(button);
            expect(rect.overlaps(launcher), isFalse);
            expect(rect.top, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(rect.bottom, lessThanOrEqualTo(size.height));
            expect(button.hitTestable(), findsOneWidget);
          }
          // Keep the audience selected on screen; hint disclosure does not
          // change its value or silently replace the publishing confirmation.
          expect(find.text('将通知到全公司所有员工'), findsOneWidget);
          final title = tester.widget<TextFormField>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (widget) => widget is TextField && widget.maxLength == 200,
              ),
              matching: find.byType(TextFormField),
            ),
          );
          expect(title.validator?.call(''), isNotNull);
          final content = tester.widget<TextFormField>(
            find.ancestor(
              of: find.byWidgetPredicate(
                (widget) => widget is TextField && widget.maxLength == 20000,
              ),
              matching: find.byType(TextFormField),
            ),
          );
          expect(content.validator?.call(''), isNotNull);

          tester
              .widget<NoticeTypePicker>(find.byType(NoticeTypePicker))
              .onChanged(NoticeType.urgent);
          await tester.pumpAndSettle();
          expect(find.textContaining('紧急通知会使用高优先级提醒'), findsOneWidget);

          tester
              .widget<UtenSegmentRow<NoticeKind>>(
                find.byType(UtenSegmentRow<NoticeKind>),
              )
              .onSelectionChanged!({NoticeKind.todo});
          await tester.pumpAndSettle();
          expect(find.text('接收人仍需具备目标页面权限。'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await fixture.dispose(tester);
        }
      },
    );
  }
}
