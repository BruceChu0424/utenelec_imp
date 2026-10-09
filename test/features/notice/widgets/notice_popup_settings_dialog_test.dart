// 个人通知弹窗开关对话框（V833/ADR-172）：
//   · 通知页「通知设置」入口：分「我会收到的弹窗」（可开关）与「其它类别」（当前岗位
//     不会收到，仅浏览）两组——全目录展示，我该收什么由资格决定；
//   · 即时保存：关闭调 setPopupPreference(disabled: true)，开启调 disabled: false；
//   · 保存失败回滚本地状态并提示；无适用类别时给说明文案。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/notice_popup_settings_dialog.dart';

class _Repo implements NoticeRepository {
  List<NoticePopupPreference> prefs = const [];
  final calls = <(String, bool)>[];
  Object? Function(String sourceEvent, bool disabled)? failWhen;

  @override
  Future<List<NoticePopupPreference>> popupPreferences() async => prefs;

  @override
  Future<void> setPopupPreference(
    String sourceEvent, {
    required bool disabled,
  }) async {
    final failure = failWhen?.call(sourceEvent, disabled);
    if (failure != null) throw failure;
    calls.add((sourceEvent, disabled));
    prefs = prefs
        .map(
          (item) => item.sourceEvent == sourceEvent
              ? NoticePopupPreference(
                  sourceEvent: item.sourceEvent,
                  label: item.label,
                  applicable: item.applicable,
                  popupDisabled: disabled,
                )
              : item,
        )
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

void main() {
  // 通知条自带停留计时；边产生边记，断言才稳。
  final notices = <String>[];

  Widget subject(_Repo repo) {
    final container = ProviderContainer(
      overrides: [noticeRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);
    notices.clear();
    container.listen<List<AppNotification>>(
      appNotificationProvider,
      (previous, next) => notices.addAll(next.map((item) => item.message)),
      fireImmediately: true,
    );
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
  }

  Future<void> open(WidgetTester tester, _Repo repo) async {
    await tester.pumpWidget(subject(repo));
    final context = tester.element(find.byType(SizedBox));
    // 不等待返回值：关闭对话框属于测试收尾，不在此断言。
    showNoticePopupSettingsDialog(context);
    await tester.pumpAndSettle();
  }

  testWidgets('groups applicable categories with switches and others '
      'without', (tester) async {
    final repo = _Repo()
      ..prefs = const [
        NoticePopupPreference(
          sourceEvent: 'SALES_ORDER_APPROVED',
          label: '新订单待物料分析',
          applicable: true,
          popupDisabled: false,
        ),
        NoticePopupPreference(
          sourceEvent: 'STOCK_COUNT_PENDING_WAREHOUSE_REVIEW',
          label: '内料仓盘点待审核',
          applicable: true,
          popupDisabled: true,
        ),
        NoticePopupPreference(
          sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
          label: '车间任务待办理',
          applicable: false,
          popupDisabled: false,
        ),
      ];
    await open(tester, repo);

    expect(find.text('我会收到的弹窗（2）'), findsOneWidget);
    expect(find.text('其它类别（当前岗位不会收到）（1）'), findsOneWidget);
    expect(find.text('新订单待物料分析'), findsOneWidget);
    expect(find.text('车间任务待办理'), findsOneWidget);
    // 只有适用类别带开关；其它类别不可关（收不到的东西没有可关的对象）。
    expect(
      find.byKey(const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED')),
      findsOneWidget,
    );
    expect(
      find.byKey(
        const ValueKey(
          'popup-pref-switch-PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
        ),
      ),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED')),
    );
    await tester.pumpAndSettle();
    expect(repo.calls, [('SALES_ORDER_APPROVED', true)]);
    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED'),
            ),
          )
          .value,
      isFalse,
      reason: '保存成功后开关反映新状态',
    );

    await tester.tap(
      find.byKey(const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED')),
    );
    await tester.pumpAndSettle();
    expect(repo.calls.last, ('SALES_ORDER_APPROVED', false));
  });

  testWidgets('failed save keeps the previous switch state and reports', (
    tester,
  ) async {
    final repo = _Repo()
      ..prefs = const [
        NoticePopupPreference(
          sourceEvent: 'SALES_ORDER_APPROVED',
          label: '新订单待物料分析',
          applicable: true,
          popupDisabled: false,
        ),
      ]
      ..failWhen = (_, disabled) => disabled ? Exception('boom') : null;
    await open(tester, repo);

    await tester.tap(
      find.byKey(const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED')),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Switch>(
            find.byKey(
              const ValueKey('popup-pref-switch-SALES_ORDER_APPROVED'),
            ),
          )
          .value,
      isTrue,
      reason: '保存失败回滚本地状态',
    );
    expect(notices, contains('保存失败，请稍后重试'));
  });

  testWidgets('no applicable category shows an inline explanation', (
    tester,
  ) async {
    final repo = _Repo()
      ..prefs = const [
        NoticePopupPreference(
          sourceEvent: 'PRODUCTION_WORKSHOP_TASK_ACTION_REQUIRED',
          label: '车间任务待办理',
          applicable: false,
          popupDisabled: false,
        ),
      ];
    await open(tester, repo);

    expect(find.text('我会收到的弹窗（0）'), findsOneWidget);
    expect(find.text('当前没有会弹窗提醒的类别；获得新的任务权限后会自动出现。'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
  });
}
