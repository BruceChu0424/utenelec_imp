import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../auth/permissions.dart';
import '../providers/session_provider.dart';
import 'attachment.dart';
import 'attachment_section.dart';
import 'attachment_service.dart';

typedef BusinessAttachmentOwner = ({String type, String id});

/// Cache belongs to the current viewer and object; a permission/session change
/// must discard private filenames as well as the ability to download the bytes.
final businessAttachmentsProvider = FutureProvider.autoDispose
    .family<List<Attachment>, BusinessAttachmentOwner>((ref, owner) async {
      ref.watch(sessionProvider);
      final permissions = ref.watch(currentPermissionsProvider);
      if (!permissions.contains(Perm.attachmentView)) return const [];
      return ref
          .watch(attachmentServiceProvider)
          .list(ownerType: owner.type, ownerId: owner.id);
    });

/// The detail page supplies its current object/price/state capabilities. The
/// shared section adds attachment permissions; the server locks and rechecks
/// the actual document on upload confirmation and deletion.
class BusinessAttachmentSection extends ConsumerWidget {
  const BusinessAttachmentSection({
    super.key,
    required this.ownerType,
    required this.ownerId,
    required this.canView,
    required this.canManage,
    this.title = '相关文件',
    this.categories,
  });

  final String ownerType;
  final String ownerId;
  final bool canView;
  final bool canManage;
  final String title;
  final List<String>? categories;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!canView ||
        !ref.watch(currentPermissionsProvider).contains(Perm.attachmentView)) {
      return const SizedBox.shrink();
    }
    final provider = businessAttachmentsProvider((
      type: ownerType,
      id: ownerId,
    ));
    final result = ref.watch(provider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: result.when(
          skipLoadingOnRefresh: false,
          skipLoadingOnReload: false,
          loading: () => const Padding(
            padding: EdgeInsets.all(UtenSpacing.s12),
            child: Center(
              child: CircularProgressIndicator(semanticsLabel: '正在读取文件'),
            ),
          ),
          error: (_, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: UtenSpacing.s8),
              const Text('文件暂时无法读取，请重试；如果权限已调整，请刷新单据。'),
              TextButton.icon(
                onPressed: () => ref.invalidate(provider),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重新读取'),
              ),
            ],
          ),
          data: (files) => AttachmentSection(
            ownerType: ownerType,
            ownerId: ownerId,
            attachments: files,
            ownerCanUpload: canManage,
            ownerCanDelete: canManage,
            title: title,
            emptyHint: canManage ? '可添加合同、图片或确认文件，方便随单查找。' : '这张单据还没有相关文件。',
            categories: categories,
            onChanged: () => ref.invalidate(provider),
          ),
        ),
      ),
    );
  }
}
