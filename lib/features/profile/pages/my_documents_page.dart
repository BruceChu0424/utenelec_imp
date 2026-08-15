// 我的文件（员工自服务）：只读查看本人档案文件（合同/证件/学历/照片/其他）。
// 数据走通用附件接口 ownerType=EMPLOYEE；EmployeeAttachmentAccessPolicy 放行本人查看。
// 上传/删除由 HR 在员工详情页"档案文件"Tab 操作（仅 HR 管理）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../shared/attachments/attachment.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../providers/profile_change_providers.dart';

class MyDocumentsPage extends ConsumerStatefulWidget {
  const MyDocumentsPage({super.key});

  @override
  ConsumerState<MyDocumentsPage> createState() => _MyDocumentsPageState();
}

class _MyDocumentsPageState extends ConsumerState<MyDocumentsPage> {
  List<Attachment>? _attachments;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final employeeId = ref.read(myEmployeeProfileProvider).valueOrNull?.id;
    if (employeeId == null) {
      setState(() {
        _loading = false;
        _error = '未找到本人员工档案';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(attachmentServiceProvider)
          .list(ownerType: 'EMPLOYEE', ownerId: employeeId);
      if (!mounted) return;
      setState(() {
        _attachments = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    const l10nNotFound = '暂无档案文件';
    return Scaffold(
      appBar: UtenAppBar(
        title: '我的文件',
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(message: _error, actionLabel: '重试', onAction: _load)
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    '你的档案文件由人事统一维护。可查看 / 下载，如需更新请联系人事。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  AttachmentSection(
                    ownerType: 'EMPLOYEE',
                    ownerId:
                        ref.read(myEmployeeProfileProvider).valueOrNull?.id ??
                        '',
                    attachments: _attachments ?? const [],
                    canManage: false,
                    onChanged: _load,
                    title: '我的档案文件',
                    emptyHint: l10nNotFound,
                  ),
                ],
              ),
            ),
    );
  }
}
