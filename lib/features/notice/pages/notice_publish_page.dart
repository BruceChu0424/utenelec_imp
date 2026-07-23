// 通知发布页（Phase 2）
// 文档：docs/03-页面/通知发布页.md

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/ui/app_notification.dart';

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

  // Backend option codes are unchanged; labels come from l10n at build time.
  static const _typeCodes = ['公告', '制度', '福利', '系统', '紧急'];
  static const _departmentCodes = ['生产部', '质量部', '人事部', '财务部'];

  @override
  void dispose() {
    _title.dispose();
    _content.dispose();
    super.dispose();
  }

  String _typeLabel(AppLocalizations l10n, String code) => switch (code) {
    '公告' => l10n.noticeTypeAnnouncement,
    '制度' => l10n.noticeTypePolicy,
    '福利' => l10n.noticeTypeBenefit,
    '系统' => l10n.noticeTypeSystem,
    '紧急' => l10n.noticeTypeUrgent,
    _ => code,
  };

  String _departmentLabel(AppLocalizations l10n, String code) => switch (code) {
    '生产部' => l10n.payrollDeptProduction,
    '质量部' => l10n.payrollDeptQuality,
    '人事部' => l10n.payrollDeptHr,
    '财务部' => l10n.payrollDeptFinance,
    _ => code,
  };

  /// 发布按钮的回调：校验 → 二次确认 → 模拟发请求 → 顶部绿色提示 → 跳列表页。
  /// 由 UtenActionButton 自管 loading-state 与防连点（点完一次后置忙，回执到达才解锁）。
  Future<void> _onPublish() async {
    final l10n = AppLocalizations.of(context);
    // 1) 校验（在按钮上，提前拦截比"点了再告诉用户哪里缺"更友好）
    if (_title.text.trim().isEmpty) {
      if (context.mounted) context.appError(l10n.noticePublishValidateTitle);
      return;
    }
    if (_content.text.trim().isEmpty) {
      if (context.mounted) context.appError(l10n.noticePublishValidateContent);
      return;
    }
    // 2) 二次确认。async gap 后必须 guard 一下：BuildContext 可能已经失效
    final dialog = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.noticePublishConfirmTitle),
        content: Text(
          _scope == 0
              ? l10n.noticePublishConfirmBodyAll
              : l10n.noticePublishConfirmBodyDept(
                  _departmentLabel(l10n, _department),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.noticePublishPublishButton),
          ),
        ],
      ),
    );
    if (dialog != true) return;

    // 3) 实际请求（mock）。这里由 UtenActionButton 在调用本方法时已经置忙，
    //    等 await resolve 后按钮自动解锁，恢复可点。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;  // State 自己的 context 用 mounted 守卫足矣
    context.appSuccess(l10n.noticePublishPublished);
    context.go('/notice');
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(title: l10n.noticePublishTitle, showBackButton: true),
      bottomNavigationBar: UtenBottomActionBar(
        child: Row(
          children: [
            UtenActionButton(
              type: UtenActionButtonType.ghost,
              label: Text(l10n.noticePublishSaveDraft),
              loadingLabel: const Text('保存中…'),
              onAction: () async {
                await Future<void>.delayed(const Duration(milliseconds: 400));
                if (context.mounted) context.appInfo(l10n.noticePublishDraftSaved);
              },
            ),
            const SizedBox(width: 12),
            Expanded(
              child: UtenActionButton(
                type: UtenActionButtonType.primary,
                isExpanded: true,
                icon: Icons.send_rounded,
                label: Text(l10n.noticePublishPublishButton),
                loadingLabel: const Text('发布中…'),
                onAction: _onPublish,
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
                              for (final t in _typeCodes)
                                DropdownMenuItem(
                                  value: t,
                                  child: Text(_typeLabel(l10n, t)),
                                ),
                            ],
                            onChanged: (v) => setState(() => _type = v!),
                          ),
                          const Spacer(),
                          Text(l10n.noticePublishTopPriority),
                          Switch(
                            value: _topPriority,
                            onChanged: (v) => setState(() => _topPriority = v),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _title,
                        decoration: InputDecoration(
                          hintText: l10n.noticePublishTitleHint,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _content,
                        maxLines: 8,
                        decoration: InputDecoration(
                          hintText: l10n.noticePublishContentHint,
                          border: const OutlineInputBorder(),
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                UtenSectionHeader(title: l10n.noticePublishScopeTitle),
                const SizedBox(height: 8),
                UtenCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<int>(
                        segments: [
                          ButtonSegment(
                            value: 0,
                            label: Text(l10n.noticePublishScopeAll),
                          ),
                          ButtonSegment(
                            value: 1,
                            label: Text(l10n.noticePublishScopeDept),
                          ),
                        ],
                        selected: {_scope},
                        onSelectionChanged: (s) =>
                            setState(() => _scope = s.first),
                      ),
                      if (_scope == 1) ...[
                        const SizedBox(height: 12),
                        DropdownButtonFormField<String>(
                          initialValue: _department,
                          decoration: InputDecoration(
                            labelText: l10n.noticePublishFieldDept,
                            border: const OutlineInputBorder(),
                          ),
                          items: [
                            for (final d in _departmentCodes)
                              DropdownMenuItem(
                                value: d,
                                child: Text(_departmentLabel(l10n, d)),
                              ),
                          ],
                          onChanged: (v) => setState(() => _department = v!),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        _scope == 0
                            ? l10n.noticePublishScopeAllHint
                            : l10n.noticePublishScopeDeptHint(
                                _departmentLabel(l10n, _department),
                              ),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
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
}
