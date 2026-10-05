// 审计「数据变更」标签页：员工证件与加密列(employee_sensitive)。
//
// 锁住三件事：列名全是中文(没有「其他字段」「未登记字段」)；证件号校验结果的存储码
// 翻成录入时同一句说明(没有 check_digit、length:17 这类原码)；密文列和只记了列名的
// 敏感列只说改了，任何地方(含展开的原始数据)都不出现密文。
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/utils/id_card_utils.dart';
import 'package:uten_imp/features/admin/models/audit_log_entry.dart';
import 'package:uten_imp/features/admin/pages/admin_audit_log_page.dart';
import 'package:uten_imp/features/admin/repositories/audit_log_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

/// 假密文：形如真实 pgcrypto 输出的开头，测试只认这个前缀。
const _cipherA = 'ww0EBwMCtestOnlyCipherAAAA';
const _cipherB = 'ww0EBwMCtestOnlyCipherBBBB';
const _requestId = '123e4567-e89b-42d3-a456-426614174001';

/// 人看的界面上不能出现的东西：密文、列名原文、校验结果原码。
final _forbidden = RegExp(
  r'ww0E|_enc\b|_hash\b|id_card|_redacted_changes|check_digit|length:|'
  r'character:|birth_future|\bunchecked\b|\bunreadable\b|\bvalid\b|'
  r'其他字段|未登记字段',
);

AuditLogDetail _sensitiveUpdate({
  int id = 1,
  String? requestId,
  required Map<String, String> before,
  required Map<String, Object> after,
}) {
  String json(Map<String, Object> map) => [
    '{',
    map.entries
        .map(
          (e) => e.value is List
              ? '"${e.key}": [${(e.value as List).map((v) => '"$v"').join(', ')}]'
              : '"${e.key}": "${e.value}"',
        )
        .join(', '),
    '}',
  ].join();
  return AuditLogDetail(
    id: id,
    action: 'update',
    targetType: 'employee_sensitive',
    objectLabel: '员工敏感信息',
    actionLabel: '修改',
    summary: '修改员工敏感信息',
    eventSource: 'database',
    result: 'success',
    resultLabel: '成功',
    requestId: requestId,
    beforeJson: json(before),
    afterJson: json(after),
    createdAt: '2026-10-05T09:00:00+08:00',
  );
}

void main() {
  testWidgets(
    'identity correction row reads in plain Chinese without ciphertext',
    (tester) async {
      final detail = _sensitiveUpdate(
        before: {'id_card_check': 'check_digit', 'birth_date_enc': _cipherA},
        after: {
          'id_card_check': 'valid',
          'birth_date_enc': _cipherB,
          '_redacted_changes': ['id_card_enc', 'id_card_hash'],
        },
      );
      await _openChangeTab(tester, _Repository({1: detail}));

      expect(find.text('共 4 个字段发生变化'), findsOneWidget);
      expect(find.text('证件号校验结果'), findsOneWidget);
      expect(find.text(IdCardProblem.checkDigit.message), findsOneWidget);
      expect(find.text('通过'), findsOneWidget);
      for (final label in ['出生日期', '证件号码', '证件号码查重值']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('已修改(内容不显示)'), findsNWidgets(3));
      // 取文字的方式确实看得到前后值，下面的「没有泄露」检查才不是空过。
      expect(_texts(tester), contains(IdCardProblem.checkDigit.message));
      _expectNothingForbidden(tester);

      // 展开的原始数据保留列名(给技术排查)，但密文内容同样不显示。
      for (final label in ['查看变更前原始数据', '查看变更后原始数据']) {
        await tester.ensureVisible(find.text(label));
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
      expect(
        find.textContaining('"birth_date_enc": "(内容不显示)"'),
        findsNWidgets(2),
      );
      expect(_texts(tester).where((text) => text.contains('ww0E')), isEmpty);
    },
  );

  testWidgets('every stored check code shows the same sentence as data entry', (
    tester,
  ) async {
    final detail = _sensitiveUpdate(
      before: {'id_card_check': 'length:17'},
      after: {'id_card_check': 'unreadable'},
    );
    await _openChangeTab(tester, _Repository({1: detail}));

    expect(find.text('证件号校验结果'), findsOneWidget);
    expect(find.text(IdCardProblem.length(17).message), findsOneWidget);
    expect(find.text('身份证号应为18位，当前为17位'), findsOneWidget);
    expect(find.text('读取不出来'), findsOneWidget);
    _expectNothingForbidden(tester);
  });

  testWidgets(
    'a new sensitive row says which fields were filled, not their content',
    (tester) async {
      const detail = AuditLogDetail(
        id: 1,
        action: 'insert',
        targetType: 'employee_sensitive',
        objectLabel: '员工敏感信息',
        summary: '新建员工敏感信息',
        eventSource: 'database',
        result: 'success',
        afterJson:
            '{"id_card_check": "unchecked", "birth_date_enc": "$_cipherA", '
            '"huji_address_enc": "$_cipherB", "email_enc": null, '
            '"political_status_enc": null}',
        createdAt: '2026-10-05T09:00:00+08:00',
      );
      await _openChangeTab(tester, _Repository({1: detail}));

      expect(find.text('共 3 个字段发生变化'), findsOneWidget);
      expect(find.text('未校验'), findsOneWidget);
      expect(find.text('出生日期'), findsOneWidget);
      expect(find.text('户籍地址'), findsOneWidget);
      expect(find.text('已填写(内容不显示)'), findsNWidgets(2));
      _expectNothingForbidden(tester);
    },
  );

  testWidgets(
    'related change card of the same operation hides ciphertext too',
    (tester) async {
      const primary = AuditLogDetail(
        id: 1,
        action: 'change_employee_identity',
        actionLabel: '修改证件信息',
        summary: '修改员工证件信息',
        result: 'success',
        requestId: _requestId,
        createdAt: '2026-10-05T09:00:00+08:00',
      );
      final related = _sensitiveUpdate(
        id: 2,
        requestId: _requestId,
        before: {'id_card_check': 'birth_future', 'birth_date_enc': _cipherA},
        after: {
          'id_card_check': 'valid',
          'birth_date_enc': _cipherB,
          '_redacted_changes': ['id_card_enc'],
        },
      );
      final repository = _Repository(
        {1: primary, 2: related},
        relatedRows: const [
          AuditLogEntry(
            id: 2,
            action: 'update',
            targetType: 'employee_sensitive',
            objectLabel: '员工敏感信息',
            summary: '修改员工敏感信息',
            eventSource: 'database',
            requestId: _requestId,
          ),
        ],
      );
      await _openChangeTab(tester, repository);

      expect(find.text('本次操作产生 1 组业务变化'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('audit-related-change-2')));
      await tester.pumpAndSettle();

      expect(find.text('完整字段详情'), findsOneWidget);
      expect(find.text('证件号校验结果'), findsOneWidget);
      expect(find.text(IdCardProblem.birthFuture.message), findsOneWidget);
      expect(find.text('通过'), findsOneWidget);
      expect(find.text('出生日期：已修改(内容不显示)'), findsOneWidget);
      expect(find.text('证件号码：已修改(内容不显示)'), findsOneWidget);
      _expectNothingForbidden(tester);
    },
  );
}

Future<void> _openChangeTab(
  WidgetTester tester,
  AuditLogRepository repository,
) async {
  tester.view.physicalSize = const Size(1440, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        auditLogRepositoryProvider.overrideWithValue(repository),
        sharedPreferencesProvider.overrideWithValue(preferences),
        masterNameServiceProvider.overrideWithValue(
          MasterNameService(_NameApi()),
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAuditLogDetailViewer(
                  context: context,
                  ref: ref,
                  entry: const AuditLogEntry(id: 1, action: 'update'),
                ),
                child: const Text('打开审计详情'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开审计详情'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(Tab, '数据变更'));
  await tester.pumpAndSettle();
}

/// 当前树里所有给人看的文字(含可选中文字和输入框内容)。
List<String> _texts(WidgetTester tester) => [
  for (final widget in tester.allWidgets)
    if (widget is Text)
      widget.data ?? widget.textSpan?.toPlainText() ?? ''
    else if (widget is SelectableText)
      widget.data ?? widget.textSpan?.toPlainText() ?? ''
    else if (widget is RichText)
      widget.text.toPlainText()
    else if (widget is EditableText)
      widget.controller.text,
];

void _expectNothingForbidden(WidgetTester tester) {
  final leaks = _texts(tester).where(_forbidden.hasMatch).toList();
  expect(leaks, isEmpty, reason: '界面上出现了密文、列名原文或校验原码');
}

class _NameApi extends ApiClient {
  _NameApi() : super(Dio());

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
}

class _Repository implements AuditLogRepository {
  _Repository(this.details, {this.relatedRows = const []});

  final Map<int, AuditLogDetail> details;
  final List<AuditLogEntry> relatedRows;

  @override
  Future<AuditLogDetail> detail(int id) async => details[id]!;

  @override
  Future<AuditLogPage> list({
    int page = 1,
    int size = 20,
    String? action,
    String? actorId,
    String? actorAccount,
    String? keyword,
    String? targetType,
    String? targetId,
    String? eventSource,
    String? requestId,
    String? operationKind,
    String? actorScope,
    bool activityOnly = true,
    int? snapshotId,
    String? riskLevel,
    String? eventCategory,
    String? outcome,
    String? dateFrom,
    String? dateTo,
  }) async => AuditLogPage(
    items: relatedRows,
    page: 1,
    size: size,
    total: relatedRows.length,
    totalPages: 1,
    snapshotId: 0,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
