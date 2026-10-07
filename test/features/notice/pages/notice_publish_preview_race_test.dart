import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/inputs/uten_employee_picker.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/notice/models/notice.dart';
import 'package:uten_imp/features/notice/pages/notice_publish_page.dart';
import 'package:uten_imp/features/notice/providers/notice_providers.dart';
import 'package:uten_imp/features/notice/repositories/notice_repository.dart';
import 'package:uten_imp/features/notice/widgets/notice_type_picker.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

void main() {
  testWidgets('A to B to A accepts only the newest preview for A', (
    tester,
  ) async {
    final repository = _PreviewRepository();
    await _mount(tester, repository);
    await _select(tester, 'a');
    await _select(tester, 'b');
    await _select(tester, 'a');

    repository.requests[2].complete('最新甲');
    await tester.pump();
    repository.requests[1].complete('过期乙');
    repository.requests[0].complete('过期甲');
    await tester.pumpAndSettle();

    expect(_title(tester).text, '最新甲标题');
    expect(find.text('最新甲模板'), findsOneWidget);
    expect(find.text('过期甲模板'), findsNothing);
    expect(find.text('过期乙模板'), findsNothing);
    expect(_picker(tester).initial?.id, 'a');
  });

  testWidgets('clearing the person invalidates its pending preview', (
    tester,
  ) async {
    final repository = _PreviewRepository();
    await _mount(tester, repository);
    await _select(tester, 'a');
    await _select(tester, null);

    repository.requests.single.complete('已清空甲');
    await tester.pumpAndSettle();

    expect(_title(tester).text, isEmpty);
    expect(_picker(tester).initial, isNull);
    expect(find.text('已清空甲模板'), findsNothing);
  });

  testWidgets('changing celebration type ignores the old response and error', (
    tester,
  ) async {
    final repository = _PreviewRepository();
    await _mount(tester, repository);
    await _select(tester, 'a');
    tester
        .widget<NoticeTypePicker>(find.byType(NoticeTypePicker))
        .onChanged(NoticeType.anniversary);
    await tester.pump();
    await _select(tester, 'a');
    expect(repository.requests.last.type, NoticeType.anniversary);

    repository.requests.last.complete('周年甲');
    await tester.pump();
    repository.requests.first.result.completeError(
      ApiException('PREVIEW_FAILED', '过期生日预览失败'),
    );
    await tester.pumpAndSettle();

    expect(_title(tester).text, '周年甲标题');
    expect(find.text('周年甲模板'), findsOneWidget);
    expect(find.textContaining('过期生日预览失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('late preset person cannot replace a manually selected person', (
    tester,
  ) async {
    final repository = _PreviewRepository();
    await _mount(tester, repository, presetSubjectId: 'preset');
    expect(repository.requests.single.employeeId, 'preset');
    await _select(tester, 'b');

    repository.requests.last.complete('新选乙');
    await tester.pump();
    repository.requests.first.complete('预设甲');
    await tester.pumpAndSettle();

    expect(_picker(tester).initial?.id, 'b');
    expect(_title(tester).text, '新选乙标题');
    expect(find.text('新选乙模板'), findsOneWidget);
    expect(find.text('预设甲模板'), findsNothing);
  });

  testWidgets('preset preview preserves a title edited while loading', (
    tester,
  ) async {
    final repository = _PreviewRepository();
    await _mount(tester, repository, presetSubjectId: 'preset');
    _title(tester).text = '我写的标题';

    repository.requests.single.complete('预设甲');
    await tester.pumpAndSettle();

    expect(_picker(tester).initial?.id, 'preset');
    expect(_title(tester).text, '我写的标题');
    expect(find.text('预设甲模板'), findsOneWidget);
  });
}

Future<void> _mount(
  WidgetTester tester,
  _PreviewRepository repository, {
  String? presetSubjectId,
}) async {
  tester.view.physicalSize = const Size(1400, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        noticeRepositoryProvider.overrideWithValue(repository),
        authenticatedScopeProvider.overrideWithValue(null),
        apiBaseUrlProvider.overrideWithValue('https://example.invalid'),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: NoticePublishPage(
          presetType: NoticeType.birthday,
          presetSubjectId: presetSubjectId,
        ),
      ),
    ),
  );
  await tester.pump();
}

UtenEmployeePicker _picker(WidgetTester tester) =>
    tester.widget<UtenEmployeePicker>(find.byType(UtenEmployeePicker));

Future<void> _select(WidgetTester tester, String? id) async {
  _picker(tester).onChanged(
    id == null ? null : UtenEmployeePickerItem(id: id, name: '员工$id'),
  );
  await tester.pump();
}

TextEditingController _title(WidgetTester tester) => tester
    .widget<TextField>(
      find.byWidgetPredicate(
        (widget) => widget is TextField && widget.maxLength == 200,
      ),
    )
    .controller!;

class _PreviewRequest {
  _PreviewRequest(this.employeeId, this.type);

  final String employeeId;
  final NoticeType type;
  final result = Completer<NoticeCelebrationPreview>();

  void complete(String value) => result.complete(
    NoticeCelebrationPreview(
      subjectName: value,
      eventLabel: value,
      suggestedTitle: '$value标题',
      suggestedTemplates: ['$value模板'],
    ),
  );
}

class _PreviewRepository implements NoticeRepository {
  final requests = <_PreviewRequest>[];

  @override
  Future<NoticeCelebrationPreview> previewCelebration({
    required String employeeId,
    required NoticeType type,
  }) {
    final request = _PreviewRequest(employeeId, type);
    requests.add(request);
    return request.result.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
