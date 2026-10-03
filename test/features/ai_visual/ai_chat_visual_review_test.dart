// Opt-in actual widget captures with synthetic business data:
// flutter test --no-pub --dart-define=UTEN_CAPTURE_UI=true test/features/ai_visual/ai_chat_visual_review_test.dart
import 'package:flutter/material.dart';
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
  for (final variant in ['desktop', 'mobile', 'authorization-dark']) {
    final mobile = variant != 'desktop';
    final grant = variant == 'authorization-dark';
    testWidgets('chat $variant renders current-page guidance', (tester) async {
      debugDisableShadows = false;
      await setCaptureView(tester, mobile ? kMobile : kDesktop);
      await tester.pumpWidget(
        captureApp(
          dark: grant,
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
              _VisualChatRepository(grant: grant),
            ),
            aiJobRunnerProvider.overrideWithValue(AiJobRunner(_VisualJobs())),
          ],
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('ai-chat-launcher')));
      await tester.pumpAndSettle();
      if (!mobile) {
        await capture(tester, 'chat-desktop-welcome');
      }
      await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')),
        grant ? '请给示例员工加授销售价格查看权限。' : '交货日期应该怎么填？给我一个例子。',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
      await tester.pumpAndSettle();
      await capture(tester, 'chat-$variant');
      expect(find.text(AppLocalizationsZh().aiChatPageAware), findsOneWidget);
      debugDisableShadows = true;
    }, skip: !kCaptureUi);
  }
}

class _VisualChatRepository implements AiChatRepository {
  const _VisualChatRepository({this.grant = false});
  final bool grant;
  @override
  Future<AiChatCapabilities> capabilities() async => const AiChatCapabilities(
    canChat: true,
    available: true,
    canUploadSalesOrder: true,
    canManagePermissions: true,
    scopeSummary: '可以帮你填写业务单据、整理客户报价，并查询你有权访问的信息。',
    suggestions: ['根据报价文件生成订货单', '我现在可以使用哪些功能？'],
  );

  @override
  Future<AiJobSnapshot> send({
    required String message,
    String? previousJobId,
    String? attachmentJobId,
    String? currentRoute,
  }) async => AiJobSnapshot(
    id: 'visual-chat-1',
    kind: 'ERP_CHAT',
    status: AiJobStatus.succeeded,
    result: {
      'reply': grant
          ? '已准备授权建议，请核对后确认。'
          : '在当前订货单中，「交货日期」填写你与客户约定的交付日期。\n\n示例：如果双方约定 10 月 20 日交付，可以选择 2026-10-20。这里的日期仅为示例，请以实际约定为准。\n\n我只根据页面说明提供帮助，没有读取你表单中已填写的内容。',
      'actions': <Map<String, dynamic>>[
        if (grant)
          {
            'type': 'CONFIRM_PERMISSION_GRANT',
            'proposalId': 'visual.only.token',
            'title': '确认授予个人权限',
            'summary': '该操作仅加授以下一项权限，完成后可在权限管理中核查。',
            'targetName': '示例员工(销售业务部)',
            'permissionCode': 'sales_order:price:view',
            'permissionName': '查看销售订货单价格、折扣与金额字段',
            'scopeSummary': '保留该员工当前获准的数据范围；本次授权不扩大客户或部门范围。',
            'expiresAt': DateTime.now()
                .add(const Duration(minutes: 5))
                .toIso8601String(),
          },
      ],
    },
  );

  @override
  Future<String> confirmPermissionGrant(String proposalId) async =>
      throw StateError('Visual fixture does not grant access');
}

class _VisualJobs implements AiJobRepository {
  @override
  Future<void> cancel(String jobId) async {}
  @override
  Future<AiJobSnapshot> get(String jobId) async =>
      throw StateError('No polling in visual fixture');
  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async =>
      throw StateError('No upload in visual fixture');
}
