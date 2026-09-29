// 「草稿(N)」顶栏按钮 + 独立草稿页（2026-09-27）。
//
// 背景：基础资料/建议箱/HR 工作台/品质任务中心此前用 [FormDraftCategoryHost] 在
// 页面左上角挂「内容|草稿(N)」分段栏，常驻占一整行。用户口径：左上角分段栏
// 不要——草稿入口以按钮样式放右上角（深绿实心 + 红底白字计数徽章，与
// [UtenDraftsButton] 同款），点击进入独立草稿页，返回键即回宿主页；草稿页的
// 「已选 N 项」胶囊随悬浮组沉到右下角（全站悬浮组口径）。
//
// 通知列表页（挂在 MainShell 下无自有 AppBar）2026-09-28 也撤了
// FormDraftCategoryHost：发布页草稿走自身 FormDraftMixin 自动保存/恢复，
// 列表页不再展示「通知|草稿」分段栏。
//
// 注册表以路由段 `:categoryId` 为键：按钮只报 id，落点页按 id 找 scope——
// scope 带 BadgeModule 枚举与集合，不适合整份塞进 URL。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_app_bar_action_button.dart';
import '../../components/feedback/uten_empty.dart';
import '../../components/feedback/uten_notification_badge.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/router/nav_helpers.dart';
import '../../core/router/route_names.dart';
import 'form_draft_category.dart';

/// 一个宿主页在独立草稿页上的登记项。
class FormDraftsPageCategory {
  const FormDraftsPageCategory({
    required this.id,
    required this.hubTitle,
    required this.scope,
  });

  /// 路由段（`/form-drafts/:categoryId` 的动态段取值）。
  final String id;

  /// 宿主页标题（tooltip 里指明草稿归属）。
  final String hubTitle;

  /// 该宿主页的草稿筛选范围。
  final FormDraftCategoryScope scope;
}

/// 独立草稿页的落点注册表；新宿主页接入时加一条，同时挂顶栏按钮即可。
const formDraftsPageCategories = <String, FormDraftsPageCategory>{
  'basicinfo': FormDraftsPageCategory(
    id: 'basicinfo',
    hubTitle: '基础资料',
    scope: FormDraftCategoryScope(routePrefix: '/basicinfo/'),
  ),
  'suggestion': FormDraftsPageCategory(
    id: 'suggestion',
    hubTitle: '建议箱',
    scope: FormDraftCategoryScope(routePath: '/suggestion/new'),
  ),
  'hr': FormDraftsPageCategory(
    id: 'hr',
    hubTitle: 'HR 工作台',
    scope: FormDraftCategoryScope(module: BadgeModule.people),
  ),
  'quality': FormDraftsPageCategory(
    id: 'quality',
    hubTitle: '品质任务中心',
    scope: FormDraftCategoryScope(module: BadgeModule.quality),
  ),
};

/// 顶栏「草稿」按钮：计数徽章与宿主分段栏同口径（含已生成单据仍待补附件的
/// 收尾草稿）；n=0 只显文案不显徽章。放 `UtenAppBar(actions: [...])` 里。
class FormDraftsAppBarButton extends ConsumerWidget {
  const FormDraftsAppBarButton({
    super.key,
    required this.categoryId,
    this.label = '草稿',
  });

  /// 注册表键（决定 scope 与落点页）。
  final String categoryId;

  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = formDraftsPageCategories[categoryId];
    if (category == null) return const SizedBox.shrink();
    final count = ref.watch(
      formDraftCategoryVisibleCountProvider(category.scope),
    );
    return UtenAppBarActionButton(
      key: ValueKey('form-drafts-button-$categoryId'),
      icon: Icons.drafts_outlined,
      label: label,
      badge: UtenNotificationBadge(count: count),
      tooltip: '「${category.hubTitle}」未完成草稿 $count 份，点击查看',
      onPressed: () =>
          goFrom(context, RouteName.formDraftsLocation(categoryId)),
    );
  }
}

/// 独立草稿页：按注册表 id 展示该宿主页的草稿表。
class FormDraftsPage extends ConsumerWidget {
  const FormDraftsPage({super.key, required this.categoryId});

  final String categoryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = formDraftsPageCategories[categoryId];
    return Scaffold(
      appBar: const UtenAppBar(title: '草稿', showBackButton: true),
      body: category == null
          ? const SafeArea(
              child: UtenEmpty(icon: Icons.drafts_outlined, message: '未知的草稿类别'),
            )
          : SafeArea(
              child: UtenContentContainer(
                child: FormDraftCategoryList(scope: category.scope),
              ),
            ),
    );
  }
}
