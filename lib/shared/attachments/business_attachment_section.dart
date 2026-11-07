import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/uten_tokens.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../auth/permissions.dart';
import '../providers/session_provider.dart';
import 'attachment.dart';
import 'attachment_section.dart';
import 'attachment_service.dart';
import 'pending_attachment_controller.dart';
import 'pending_attachment_section.dart';

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
    this.info,
    this.categories,
    this.readOnlyNote,
    this.rowActionBuilder,
    this.showBusyOverlay = false,
  }) : draftController = null,
       draftActionFor = null,
       draftHeaderExtra = null,
       draftEmptyHint = null,
       draftManageWithoutUploadPerm = false,
       draftSelectionMode = false,
       draftSelectedItems = const <PendingAttachment>{},
       draftOnToggleSelection = null,
       draftSelectableFor = null;

  /// 新建单据（尚无 UUID）的保存前暂存模式：只选文件/移除，保存成功后由页面调用
  /// [PendingAttachmentController.flush] 逐个确认到真实单据（ADR-074 不按名称关联）。
  /// [canManage] 由页面表达新建权限；组件再叠加 attachment:upload。
  /// [draftActionFor]/[draftHeaderExtra]/[draftEmptyHint] 透传给暂存卡片区（如销售的 AI 识别）。
  const BusinessAttachmentSection.draft({
    super.key,
    required PendingAttachmentController controller,
    required this.canManage,
    this.title = '相关文件',
    this.categories,
    this.draftActionFor,
    this.draftHeaderExtra,
    this.draftEmptyHint,
    this.draftManageWithoutUploadPerm = false,
    this.draftSelectionMode = false,
    this.draftSelectedItems = const <PendingAttachment>{},
    this.draftOnToggleSelection,
    this.draftSelectableFor,
  }) : draftController = controller,
       ownerType = '',
       ownerId = '',
       canView = true,
       info = null,
       rowActionBuilder = null,
       showBusyOverlay = false,
       // 新建暂存区没有「只读」形态：无权管理时整区不渲染。
       readOnlyNote = null;

  final String ownerType;
  final String ownerId;
  final bool canView;
  final bool canManage;
  final String title;
  final String? info;
  final List<String>? categories;
  final PendingAttachmentController? draftController;

  /// 见 [PendingAttachmentSection.actionFor]。
  final PendingFileActionSpec? Function(PendingAttachment item)? draftActionFor;

  /// 见 [PendingAttachmentSection.headerExtra]。
  final Widget? draftHeaderExtra;

  /// 见 [PendingAttachmentSection.emptyHint]。
  final String? draftEmptyHint;

  /// 见 [PendingAttachmentSection.manageWithoutUploadPerm]。
  final bool draftManageWithoutUploadPerm;

  /// 见 [PendingAttachmentSection.selectionMode]（批量操作前的勾选模式）。
  final bool draftSelectionMode;

  /// 见 [PendingAttachmentSection.selectedItems]。
  final Set<PendingAttachment> draftSelectedItems;

  /// 见 [PendingAttachmentSection.onToggleSelection]。
  final ValueChanged<PendingAttachment>? draftOnToggleSelection;

  /// 见 [PendingAttachmentSection.selectableFor]。
  final bool Function(PendingAttachment item)? draftSelectableFor;

  /// 见 [AttachmentSection.rowActionBuilder]（已保存单据的附件行附加动作）。
  final Widget? Function(Attachment attachment)? rowActionBuilder;

  /// Explicitly opened read-only references keep waiting feedback scoped here.
  /// Upload/edit consumers retain their existing progress presentation.
  final bool showBusyOverlay;

  /// 只读文件旁的提示图标解释查看和修改入口。
  /// 详情（审核）页统一用 [kReviewReadOnlyAttachmentNote]。
  final String? readOnlyNote;

  /// 详情/审核页的统一只读说明：单据一旦落库，文件增删只在编辑页做，
  /// 审核者看到的永远是提交时那一份（2026-09-11 用户要求）。
  static const String kReviewReadOnlyAttachmentNote =
      '本页文件只读，仅可查看和下载；需要增删请回到编辑页。';

  bool get isDraft => draftController != null;

  /// 空态举例用本页自己的词表（采购单不该写「客户确认」）。
  /// 分类本身仍是可选的：传完之后在文件旁边点一下才设，上传前不问。
  String get _emptyHint {
    final vocabulary = categories;
    if (vocabulary == null || vocabulary.isEmpty) {
      return '可添加相关文件，方便随单查找。';
    }
    return '可添加${vocabulary.take(3).join('、')}等文件，方便随单查找。';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (draftController case final controller?) {
      if (!canManage) return const SizedBox.shrink();
      if (!draftManageWithoutUploadPerm &&
          !ref
              .watch(currentPermissionsProvider)
              .contains(Perm.attachmentUpload)) {
        return const SizedBox.shrink();
      }
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: PendingAttachmentSection(
            controller: controller,
            canManage: canManage,
            title: title,
            categories: categories,
            emptyHint: draftEmptyHint,
            actionFor: draftActionFor,
            headerExtra: draftHeaderExtra,
            manageWithoutUploadPerm: draftManageWithoutUploadPerm,
            selectionMode: draftSelectionMode,
            selectedItems: draftSelectedItems,
            onToggleSelection: draftOnToggleSelection,
            selectableFor: draftSelectableFor,
          ),
        ),
      );
    }
    if (!canView ||
        !ref.watch(currentPermissionsProvider).contains(Perm.attachmentView)) {
      return const SizedBox.shrink();
    }
    final provider = businessAttachmentsProvider((
      type: ownerType,
      id: ownerId,
    ));
    final result = ref.watch(provider);
    final content = Card(
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
                onPressed: () async {
                  if (ref.read(provider).isLoading) return;
                  try {
                    if (showBusyOverlay) {
                      final pending = ref.refresh(provider.future);
                      await pending;
                    } else {
                      await UtenBusyOverlay.run(
                        context,
                        title: '正在读取相关文件',
                        action: () => ref.refresh(provider.future),
                      );
                    }
                  } catch (_) {
                    // The current provider reports the error in this card.
                  }
                },
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
            info: !canManage && files.isNotEmpty ? readOnlyNote ?? info : info,
            emptyHint: canManage ? _emptyHint : '这张单据还没有相关文件。',
            categories: categories,
            onChanged: () => ref.invalidate(provider),
            rowActionBuilder: rowActionBuilder,
          ),
        ),
      ),
    );
    return showBusyOverlay
        ? Stack(
            children: [
              content,
              if (result.isLoading)
                const UtenBusyOverlay(
                  title: '正在读取相关文件',
                  showDoNotLeaveHint: false,
                ),
            ],
          )
        : content;
  }
}
