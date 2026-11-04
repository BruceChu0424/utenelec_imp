import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/network/api_client.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/attachment.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';

typedef FinanceNativeOriginalKey = ({String ownerType, String id});

final financeNativeOriginalProvider = FutureProvider.autoDispose
    .family<
      ({Map<String, dynamic> source, List<Attachment> files}),
      FinanceNativeOriginalKey
    >(
      (ref, key) async {
        ref.watch(exportContextEpochProvider);
        ref.watch(sensitiveReadBoundaryProvider);
        final endpoint = switch (key.ownerType) {
          'BUSINESS_APPLICATION' => '/business-applications',
          'EXPENSE_CLAIM' => '/expense-claims',
          _ => throw ArgumentError.value(key.ownerType, 'ownerType'),
        };
        final source = await ref
            .watch(apiClientProvider)
            .get('$endpoint/${Uri.encodeComponent(key.id)}/original-source');
        final files = source['originalEvidenceState'] == 'AVAILABLE'
            ? await ref
                  .read(attachmentServiceProvider)
                  .listLinked(ownerType: key.ownerType, ownerId: key.id)
            : <Attachment>[];
        return (source: source, files: files);
      },
      dependencies: [
        exportContextEpochProvider,
        sensitiveReadBoundaryProvider,
        apiClientProvider,
        attachmentServiceProvider,
      ],
    );

/// Current applications expose only their own immutable reviewed source group.
/// There are no upload/delete/category controls and no old-owner list request.
class FinanceNativeOriginalSection extends ConsumerWidget {
  const FinanceNativeOriginalSection({
    super.key,
    required this.ownerType,
    required this.ownerId,
  });
  final String ownerType, ownerId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (ownerType: ownerType, id: ownerId);
    final provider = financeNativeOriginalProvider(key);
    Future<void> reload() async {
      try {
        await UtenBusyOverlay.run(
          context,
          title: '正在读取原稿',
          action: () async {
            ref.invalidate(provider);
            await ref.read(provider.future);
          },
        );
      } catch (error) {
        if (context.mounted) context.appApiError(error);
      }
    }

    return ref
        .watch(provider)
        .when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const LinearProgressIndicator(),
          error: (error, stack) => UtenButton(
            type: UtenButtonType.secondary,
            onPressed: reload,
            child: const Text('重新读取原稿及凭证'),
          ),
          data: (value) {
            if (value.source.isEmpty) return const SizedBox.shrink();
            final original = value.source['original'] is Map
                ? Map<String, dynamic>.from(value.source['original'] as Map)
                : <String, dynamic>{};
            final payload = original['payload'] is Map
                ? Map<String, dynamic>.from(original['payload'] as Map)
                : <String, dynamic>{};
            final amount = original['amountOriginal']?.toString();
            final currency =
                original['currencyCode'] ?? original['currencyName'] ?? '原币待核';
            final evidenceState =
                switch (value.source['originalEvidenceState']) {
                  'REQUIRES_ACCESS' => '当前无原凭证查阅权限',
                  'UNAVAILABLE' => '原凭证已变化或不可用，须核对原件',
                  'AVAILABLE' => '原凭证已对应',
                  _ => '无原凭证引用',
                };
            return UtenCard(
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    UtenSectionHeader(
                      title: '原稿及凭证',
                      info: '原稿和凭证保留原归属，只读查阅。当前审批、实际付款和账务关联分别办理。原件不可用时不能继续提交。',
                      trailing: UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: reload,
                        child: const Text('刷新原稿'),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    SelectableText('原申请：${original['title'] ?? '—'}'),
                    SelectableText('原申请单号：${original['applicationNo'] ?? '—'}'),
                    SelectableText('申请日期：${original['requestedDate'] ?? '—'}'),
                    SelectableText(
                      '原申请金额：${amount == null ? '— / 不适用' : '$amount $currency'}',
                    ),
                    for (final field in const {
                      'destination': '出差地点',
                      'travelStart': '出差开始日期',
                      'travelEnd': '出差结束日期',
                      'travelPurpose': '出差事由',
                      'remark': '原备注',
                    }.entries)
                      if (payload[field.key] != null)
                        SelectableText('${field.value}：${payload[field.key]}'),
                    if (payload['lines'] is List)
                      for (final line in payload['lines'] as List)
                        if (line is Map)
                          SelectableText(
                            '${line['label'] ?? '原明细'}：${line['amountOriginal'] ?? '—'} $currency',
                          ),
                    SelectableText('原凭证状态：$evidenceState'),
                    if (value.files.isNotEmpty) ...[
                      const SizedBox(height: UtenSpacing.s12),
                      AttachmentSection(
                        ownerType: ownerType,
                        ownerId: ownerId,
                        title: '原稿凭证',
                        attachments: value.files,
                        ownerCanUpload: false,
                        ownerCanDelete: false,
                        onChanged: () => ref.invalidate(provider),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
  }
}
