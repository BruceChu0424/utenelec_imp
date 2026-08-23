// 合同附件弹窗：按单份合同（ownerType=EMPLOYEE_CONTRACT）管理扫描件。
// 后端对象层：view=本人或 employee:pii:view，上传/删除=employee:edit；
// 通用层再分别叠 attachment:view/download/upload/delete。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../shared/attachments/attachment.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/attachments/attachment_service.dart';

Future<void> showContractAttachmentsDialog(
  BuildContext context, {
  required String contractId,
  required String title,
  required bool ownerCanManage,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ContractAttachmentsDialog(
      contractId: contractId,
      title: title,
      ownerCanManage: ownerCanManage,
    ),
  );
}

class _ContractAttachmentsDialog extends ConsumerStatefulWidget {
  const _ContractAttachmentsDialog({
    required this.contractId,
    required this.title,
    required this.ownerCanManage,
  });

  final String contractId;
  final String title;
  final bool ownerCanManage;

  @override
  ConsumerState<_ContractAttachmentsDialog> createState() =>
      _ContractAttachmentsDialogState();
}

class _ContractAttachmentsDialogState
    extends ConsumerState<_ContractAttachmentsDialog> {
  List<Attachment>? _attachments;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await ref
          .read(attachmentServiceProvider)
          .list(ownerType: 'EMPLOYEE_CONTRACT', ownerId: widget.contractId);
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
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close_rounded, size: 20),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 48),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _error != null
                    ? UtenEmpty.error(
                        message: _error,
                        actionLabel: '重试',
                        onAction: _load,
                      )
                    : SingleChildScrollView(
                        child: AttachmentSection(
                          ownerType: 'EMPLOYEE_CONTRACT',
                          ownerId: widget.contractId,
                          attachments: _attachments ?? const [],
                          ownerCanUpload: widget.ownerCanManage,
                          ownerCanDelete: widget.ownerCanManage,
                          onChanged: _load,
                          title: '合同附件',
                          emptyHint: widget.ownerCanManage
                              ? '暂无合同附件，点击上传该份合同的扫描件（PDF 或图片）'
                              : '暂无合同附件',
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
