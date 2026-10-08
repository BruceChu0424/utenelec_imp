// Opt-in actual widget captures with synthetic business data:
// flutter test --no-pub --dart-define=UTEN_CAPTURE_UI=true test/features/ai_visual/ai_chat_visual_review_test.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations_zh.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_models.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_overlay.dart';
import 'package:uten_imp/shared/ai/chat/ai_chat_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'ai_visual_support.dart';

void main() {
  for (final variant in [
    'desktop',
    'mobile',
    'authorization-dark',
    'failure-desktop',
    'failure-mobile',
    'composer-mobile',
    'composer-dark-large',
  ]) {
    final composer = variant.startsWith('composer');
    final mobile =
        variant == 'mobile' ||
        variant == 'failure-mobile' ||
        variant == 'authorization-dark' ||
        composer;
    final grant = variant == 'authorization-dark';
    final failure = variant.startsWith('failure');
    testWidgets('chat $variant renders current-page guidance', (tester) async {
      debugDisableShadows = false;
      await setCaptureView(
        tester,
        composer
            ? const Size(320, 844)
            : mobile
            ? kMobile
            : kDesktop,
      );
      if (variant == 'composer-dark-large') {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(
        captureApp(
          dark: grant || variant == 'composer-dark-large',
          home: AiChatOverlay(
            currentRoute: '/sales/orders/new',
            child: Scaffold(
              appBar: AppBar(title: const Text('新建订货单 · 界面审查示例')),
              body: const Padding(
                padding: EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 640,
                    child: Card(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '订单信息',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            SizedBox(height: 24),
                            TextField(
                              decoration: InputDecoration(
                                labelText: '客户',
                                hintText: '选择客户',
                                suffixIcon: Icon(Icons.expand_more),
                              ),
                            ),
                            SizedBox(height: 20),
                            TextField(
                              decoration: InputDecoration(
                                labelText: '交货日期',
                                hintText: '选择日期',
                                suffixIcon: Icon(Icons.calendar_today_outlined),
                              ),
                            ),
                            SizedBox(height: 24),
                            Text('当前示例使用模拟业务数据。'),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          overrides: [
            aiChatIdentityProvider.overrideWithValue((
              scope: const AuthenticatedScope(userId: 'visual-user'),
              server: 'https://example.test/api',
              permissions: 'ai:use\nsales_order:create',
              superAdmin: grant,
            )),
            aiChatRepositoryProvider.overrideWithValue(
              _VisualChatRepository(grant: grant, failReply: failure),
            ),
            aiJobRunnerProvider.overrideWithValue(
              AiJobRunner(_VisualJobs(failReply: failure)),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-chat-launcher')));
      await tester.pumpAndSettle();
      if (composer) {
        FilePicker.platform = _VisualPicker();
        addTearDown(() => FilePicker.platform = _VisualPicker(hasFile: false));
        await tester.tap(find.byKey(const ValueKey('ai-chat-attach')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('ai-chat-input')),
          '这是客户的报价单。\n请按原数量和价格生成订货单，先给我核对。',
        );
        await tester.pumpAndSettle();
        await capture(tester, 'chat-$variant');
        debugDisableShadows = true;
        return;
      }
      if (variant == 'desktop' || variant == 'mobile') {
        await capture(tester, 'chat-$variant-welcome');
      }
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        failure
            ? 'hello'
            : grant
            ? '请给示例员工加授销售价格查看权限。'
            : '交货日期应该怎么填？给我一个例子。',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pumpAndSettle();
      if (variant == 'failure-mobile') {
        await tester.enterText(
          find.byKey(const ValueKey('ai-chat-input')),
          '我想再问一个新的问题',
        );
        await tester.pumpAndSettle();
      }
      await capture(tester, 'chat-$variant');
      expect(find.text('销售订货单'), findsOneWidget);
      if (variant == 'mobile') {
        await tester.tap(find.byKey(const ValueKey('ai-chat-info')));
        await tester.pumpAndSettle();
        await capture(tester, 'chat-mobile-info');
        await tester.tap(find.text(AppLocalizationsZh().aiChatInfoDone));
        await tester.pumpAndSettle();
      }
      debugDisableShadows = true;
    }, skip: !kCaptureUi);
  }
}

class _VisualPicker extends FilePicker {
  _VisualPicker({this.hasFile = true});
  final bool hasFile;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => hasFile
      ? FilePickerResult([
          PlatformFile(
            name: 'SUNAS 客户报价单与订货明细.xlsx',
            size: 1,
            bytes: Uint8List.fromList([1]),
          ),
        ])
      : null;
}

class _VisualChatRepository implements AiChatRepository {
  const _VisualChatRepository({this.grant = false, this.failReply = false});
  final bool grant;
  final bool failReply;
  @override
  Future<AiChatPageSuggestions> pageSuggestions(String pageRoute) async =>
      AiChatPageSuggestions(
        pageRoute: pageRoute,
        pageTitle: '销售订货单',
        suggestions: ['订货单怎么填写？', '客户怎么选？'],
      );
  @override
  Future<AiChatCapabilities> capabilities() async => const AiChatCapabilities(
    canChat: true,
    available: true,
    canUploadSalesOrder: true,
    canUploadDocument: true,
    workflows: ['SALES_ORDER', 'SALES_QUOTE', 'EXPENSE_CLAIM'],
    canManagePermissions: true,
    scopeSummary: '可以帮你填写业务单据、整理客户报价，并查询你有权访问的信息。',
    suggestions: ['根据报价文件生成订货单', '我现在可以使用哪些功能？'],
  );

  @override
  Future<({AiChatSettings settings, bool reasoningEffortSupported})>
  updateSettings(Map<String, Object> change) async => (
    settings: AiChatSettings.defaults.withField(
      change.keys.single,
      change.values.single,
    ),
    reasoningEffortSupported: true,
  );

  @override
  Future<AiChatConversationView> conversation({String? conversationId}) async =>
      const AiChatConversationView();

  @override
  Future<void> clearConversations() async {}

  @override
  Future<List<AiChatMemorySuggestion>> memorySuggestions() async => const [];

  @override
  Future<void> clearOperationMemory() async {}

  @override
  Future<AiJobSnapshot> send({
    required String message,
    required String conversationId,
    String? currentRoute,
    String? intentHint,
    Map<String, Object?>? snapshot,
    String? locale,
  }) async => AiJobSnapshot(
    id: 'visual-chat-1',
    kind: 'ERP_CHAT',
    status: failReply ? AiJobStatus.pending : AiJobStatus.succeeded,
    result: {
      'reply': grant
          ? '已准备授权建议，请核对后确认。'
          : '「交货日期」填写与客户约定的交付日期。\n\n例如约定 10 月 20 日交货，就填 2026-10-20。',
      'actions': <Map<String, dynamic>>[
        if (grant)
          {
            'type': 'CONFIRM_ACTION',
            'proposalId': '5f0c7a3e-2b1d-4c8e-9a6f-0d1e2f3a4b5c',
            'actionType': 'PERMISSION_GRANT',
            'handler': 'PERMISSION_GRANT',
            'execution': 'SERVER',
            'title': '确认授予个人权限',
            'summaryLines': [
              '对象: 示例员工(销售业务部)',
              '权限: 查看销售订货单价格、折扣与金额字段',
              '范围: 保留该员工当前获准的数据范围',
            ],
            'risk': 'HIGH',
            'riskNote': '确认后会正式授权, 请仔细核对。',
            'requiresStepUp': true,
            'issuedAt': DateTime.now().toUtc().toIso8601String(),
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 5))
                .toUtc()
                .toIso8601String(),
            'status': 'PROPOSED',
          },
      ],
    },
  );

  @override
  Future<String> confirmPermissionGrant(String proposalId) async =>
      throw StateError('Visual fixture does not grant access');

  @override
  Future<AiChatAction> actionStatus(String proposalId) async =>
      throw StateError('Visual fixture has no card state');

  @override
  Future<({AiChatAction card, Map<String, Object?> args})> confirmAction(
    String proposalId,
  ) async => throw StateError('Visual fixture does not execute');

  @override
  Future<AiChatAction> cancelAction(String proposalId) async =>
      throw StateError('Visual fixture does not cancel');

  @override
  Future<AiChatAction> actionReceipt(
    String proposalId, {
    required bool succeeded,
    String? message,
  }) async => throw StateError('Visual fixture has no receipts');
}

class _VisualJobs implements AiJobRepository {
  const _VisualJobs({this.failReply = false});
  final bool failReply;
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> get(String jobId) async => failReply
      ? AiJobSnapshot(
          id: jobId,
          kind: 'ERP_CHAT',
          status: AiJobStatus.failed,
          errorCode: 'AI_INVALID_RESPONSE',
          errorMessage: 'AI 没有返回可处理的对话结果，请稍后重试。',
        )
      : throw StateError('No polling in visual fixture');
  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async =>
      throw StateError('No upload in visual fixture');
}
