// 我的档案文件（只读）：原独立页「我的文件」吸收进「我的」我的文件 Tab（我的页 v7）。
// 附件随 GET /profile/me 一并返回（EmployeeAttachmentAccessPolicy 放行本人可见部分；
// attachment:view 被权限管理页收回时后端降级为空列表而非 403）。
// 上传/删除由 HR 在员工详情页「档案文件」Tab 操作（仅 HR 管理）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../employee/models/employee_api_models.dart';
import '../providers/profile_change_providers.dart';

class MyDocumentsSection extends ConsumerWidget {
  const MyDocumentsSection({super.key, required this.profile});

  final EmployeeProfile profile;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canView = ref.watch(
      currentPermissionsProvider.select(
        (perms) => perms.contains(Perm.attachmentView),
      ),
    );
    if (!canView) {
      return const UtenEmpty(
        icon: Icons.folder_off_outlined,
        message: '暂无文件查看权限',
        description: '如需查看本人档案文件，请联系管理员开通附件查看权限(attachment:view)。',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '你的档案文件由人事统一维护。可查看 / 下载，如需更新请联系人事。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        AttachmentSection(
          ownerType: 'EMPLOYEE',
          ownerId: profile.id,
          attachments: profile.attachments,
          ownerCanUpload: false,
          ownerCanDelete: false,
          onChanged: () => ref.invalidate(myEmployeeProfileProvider),
          title: '我的档案文件',
          emptyHint: '暂无档案文件',
        ),
      ],
    );
  }
}
