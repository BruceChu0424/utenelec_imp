// 新建建议页
// 表单页全断点套 UtenContentContainer.narrow（maxWidth 1120）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/suggestion.dart';
import '../providers/suggestion_providers.dart';

class SuggestionNewPage extends ConsumerStatefulWidget {
  const SuggestionNewPage({super.key});

  @override
  ConsumerState<SuggestionNewPage> createState() => _SuggestionNewPageState();
}

class _SuggestionNewPageState extends ConsumerState<SuggestionNewPage> {
  SuggestionCategory _category = SuggestionCategory.process;
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  bool _isAnonymous = false;
  bool _isSubmitting = false;

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const UtenAppBar(title: '提建议', showBackButton: true),
      body: Column(
        children: [
          Expanded(
            // 表单页全断点窄版收敛（1120），避免宽屏表单被拉得过长
            child: UtenContentContainer.narrow(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                children: [
                  // 类别
                  Text(
                    '建议类别',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Wrap(
                    spacing: UtenSpacing.s8,
                    runSpacing: UtenSpacing.s8,
                    children: [
                      for (final cat in SuggestionCategory.values)
                        ChoiceChip(
                          label: Text(cat.label),
                          avatar: Icon(cat.icon, size: 16, color: cat.color),
                          selected: _category == cat,
                          selectedColor: cat.color.withValues(alpha: 0.15),
                          onSelected: (_) => setState(() => _category = cat),
                        ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenCard(
                    child: Column(
                      children: [
                        UtenInput(
                          controller: _titleController,
                          label: '标题',
                          required: true,
                          hint: '一句话概括你的建议',
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        UtenInput(
                          controller: _contentController,
                          label: '详细内容',
                          required: true,
                          hint: '详细描述你的建议，包括问题背景、改进方案、预期效果等',
                          maxLines: 8,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  // 匿名开关
                  UtenCard(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                      vertical: UtenSpacing.s8,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Row(
                          children: [
                            Icon(
                              _isAnonymous
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 20,
                            ),
                            const SizedBox(width: UtenSpacing.s12),
                            const Text('匿名提交'),
                          ],
                        ),
                        subtitle: const Text('开启后，其他同事看不到你的姓名'),
                        value: _isAnonymous,
                        onChanged: (v) => setState(() => _isAnonymous = v),
                        activeTrackColor: UtenColors.primary,
                      ),
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  // 提示
                  Container(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: UtenRadius.lgAll,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.info_outline_rounded,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(
                          child: Text(
                            '提交后建议会进入"建议广场"，所有同事可见并可点赞。人事/管理层会尽快回复处理。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          UtenBottomActionBar(
            child: UtenButton(
              isExpanded: true,
              size: UtenButtonSize.large,
              isLoading: _isSubmitting,
              icon: Icons.send_rounded,
              onPressed: _isSubmitting ? null : _submit,
              child: const Text('提交建议'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    if (_titleController.text.trim().isEmpty) {
      UtenToast.warning(context, '请填写标题');
      return;
    }
    if (_contentController.text.trim().length < 10) {
      UtenToast.warning(context, '内容请至少填写 10 字');
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final s = await submitSuggestion(
        ref,
        category: _category,
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
        isAnonymous: _isAnonymous,
      );
      if (mounted) {
        UtenToast.success(context, '提交成功，感谢您的建议！');
        context.push(RoutePath.suggestionDetail(s.id));
      }
    } catch (e) {
      if (mounted) UtenToast.error(context, '提交失败：$e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
