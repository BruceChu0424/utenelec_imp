import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../repositories/system_test_repository.dart';

/// 可选的测试维护入口：提前分批把业务附件提交删除队列。未在此清理的文件将在
/// 「清空业务数据」时由服务端自动标删并物理删除（ADR-067 §7），不再是清空前置条件。
class BusinessAttachmentResetDialog extends ConsumerStatefulWidget {
  const BusinessAttachmentResetDialog({super.key});
  @override
  ConsumerState<BusinessAttachmentResetDialog> createState() => _State();
}

class _State extends ConsumerState<BusinessAttachmentResetDialog> {
  final _confirm = TextEditingController();
  BusinessAttachmentResetPreview? _preview;
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    Future.microtask(_load);
  }

  @override
  void dispose() {
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final value = await ref
          .read(systemTestRepositoryProvider)
          .previewBusinessAttachments();
      if (mounted) {
        setState(() {
          _preview = value;
          _confirm.clear();
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = '无法核对文件，请重试');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    final preview = _preview;
    if (preview == null || _busy || _confirm.text != '清理测试业务附件') return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final next = await ref
          .read(systemTestRepositoryProvider)
          .prepareBusinessAttachments(preview);
      if (mounted) {
        setState(() {
          _preview = next;
          _confirm.clear();
        });
      }
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _preview = null;
          _confirm.clear();
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = '提交失败，请重新核对文件后重试';
          _preview = null;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return AlertDialog(
      title: const Text('清理测试业务附件'),
      content: SizedBox(
        width: 660,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .65,
          ),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  '仅用于重置测试数据。可选：提前分批清理；未清理的文件将在清空时自动删除。'
                  '以下业务文件将提交删除任务；员工档案、劳动合同和货品图片/图纸保留。请先确认备份。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                if (preview != null) ...[
                  Text('目标数据库：${preview.database}'),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    preview.blockingCount == 0
                        ? '文件已核对完成，可以返回继续清空业务数据。'
                        : '还有 ${preview.blockingCount} 项文件或删除任务未完成',
                  ),
                  if (preview.hasMore)
                    const Text('本次最多准备 100 项。处理完成后刷新，继续核对下一批。'),
                  const SizedBox(height: UtenSpacing.s8),
                  for (final item in preview.items)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.description_outlined, size: 20),
                          const SizedBox(width: UtenSpacing.s8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item['fileName']?.toString() ?? '文件'),
                                Text(item['message']?.toString() ?? '正在核对'),
                                if (DateTime.tryParse(
                                      item['waitUntil']?.toString() ?? '',
                                    )
                                    case final DateTime time)
                                  Text(
                                    '上传凭证到期：${ChinaDateTime.formatInstant(time)}',
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (preview.blockingCount > 0) ...[
                    const Text(
                      '可选：提前分批清理；未清理的文件将在清空时自动删除。'
                      '上传凭证仍有效时请等待到期后刷新；未知原件或删除失败请先由维护人员通过附件对账核对'
                      '（这类阻塞在清空时会被拒绝并列出原因）。',
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                    TextField(
                      key: const Key('business-attachment-prepare-confirm'),
                      controller: _confirm,
                      enabled: !_busy,
                      onChanged: (_) => setState(() {}),
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '请输入「清理测试业务附件」'),
                        info: '只对当前预览中的数据库和文件提交删除任务。可选：提前分批清理；未清理的文件将在清空时自动删除。',
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('返回'),
        ),
        TextButton.icon(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
          label: const Text('刷新核对'),
        ),
        if (preview != null && preview.blockingCount > 0)
          FilledButton(
            key: const Key('business-attachment-prepare-submit'),
            onPressed: !_busy && _confirm.text == '清理测试业务附件' ? _prepare : null,
            child: const Text('提交删除任务'),
          ),
      ],
    );
  }
}
