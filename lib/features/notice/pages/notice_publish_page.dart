// 通知发布页（Phase 2）
// 文档：docs/03-页面/通知发布页.md

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';

class NoticePublishPage extends StatefulWidget {
  const NoticePublishPage({super.key});

  @override
  State<NoticePublishPage> createState() => _NoticePublishPageState();
}

class _NoticePublishPageState extends State<NoticePublishPage> {
  final _title = TextEditingController();
  final _content = TextEditingController();
  String _type = '公告';
  bool _topPriority = false;
  // 可见范围：0=全员 1=按部门
  int _scope = 0;
  String _department = '生产部';
  bool _publishing = false;

  static const _types = ['公告', '制度', '福利', '系统', '紧急'];
  static const _departments = ['生产部', '质量部', '人事部', '财务部'];

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    if (_title.text.trim().isEmpty) {
      _toast('请填写标题');
      return;
    }
    if (_content.text.trim().isEmpty) {
      _toast('请填写正文');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认发布？'),
        content: Text(_scope == 0 ? '将通知到全员' : '将通知到「$_department」'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('发布')),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _publishing = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _publishing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('通知已发布（Mock）')),
      );
      context.go('/notice');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: const UtenAppBar(title: '发布通知', showBackButton: true),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => _toast('已保存草稿（Mock）'),
              child: const Text('存草稿'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: UtenButton(
                isLoading: _publishing,
                isExpanded: true,
                icon: Icons.send_rounded,
                onPressed: _publish,
                child: const Text('发布'),
              ),
            ),
          ],
        ),
      ),
      // 响应式：大屏居中限宽，小屏铺满
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // 类型 + 置顶
                      Row(
                        children: [
                          DropdownButton<String>(
                            value: _type,
                            underline: const SizedBox(),
                            items: [
                              for (final t in _types)
                                DropdownMenuItem(value: t, child: Text(t)),
                            ],
                            onChanged: (v) => setState(() => _type = v!),
                          ),
                          const Spacer(),
                          const Text('置顶'),
                          Switch(
                            value: _topPriority,
                            onChanged: (v) => setState(() => _topPriority = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _title,
                        decoration: const InputDecoration(
                          hintText: '通知标题（必填）',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _content,
                        maxLines: 8,
                        decoration: const InputDecoration(
                          hintText: '通知正文……',
                          border: OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                const UtenSectionHeader(title: '可见范围'),
                const SizedBox(height: 8),
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 0, label: Text('全员')),
                          ButtonSegment(value: 1, label: Text('按部门')),
                        ],
                        selected: {_scope},
                        onSelectionChanged: (s) => setState(() => _scope = s.first),
                      ),
                      if (_scope == 1) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _department,
                          decoration: const InputDecoration(
                            labelText: '部门',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            for (final d in _departments)
                              DropdownMenuItem(value: d, child: Text(d)),
                          ],
                          onChanged: (v) => setState(() => _department = v!),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        _scope == 0
                            ? '将通知到全公司所有员工'
                            : '将通知到「$_department」全体员工',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
