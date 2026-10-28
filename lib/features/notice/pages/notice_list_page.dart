// 通知列表页（卡片瀑布流版，支持多选删除 + 按业务对象分组叠放）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。
// 文档：docs/03-页面/通知列表页.md
//
// 多选删除：右上角「管理」进入选择模式（或长按卡片直接进入），
// 勾选多张卡片后底部操作条「删除」——从自己列表移除（他人不受影响）。
// 分组：同一业务对象（订单/报价/领料单…）的多条通知叠成一组——组卡 = 最新
// 一条完整展示 + 背后 1-2 层露边 + 「N 条相关」计数胶囊；点组卡弹窗看全部
// （未读在前，可逐条打开详情或一键已读）。单条组渲染为普通卡片。
// 筛选默认「未读」（2026-10-09 用户口径）：进通知页先看没处理过的。

import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_selection_summary_pill.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../components/buttons/click_guard.dart';
import '../models/notice.dart';
import '../models/notice_group.dart';
import '../providers/notice_providers.dart';
import '../widgets/notice_card.dart';
import '../widgets/notice_detail_dialog.dart';
import '../widgets/notice_group_dialog.dart';
import '../widgets/notice_popup_settings_dialog.dart';

class NoticeListPage extends ConsumerStatefulWidget {
  const NoticeListPage({super.key, this.initialFilter});

  /// 深链初始筛选（如 /notice?filter=important 工作台「重要通知」直达）；
  /// null 走 provider 现值（默认未读）。只消费一次，不与段内切换互斥。
  final NoticeFilter? initialFilter;

  @override
  ConsumerState<NoticeListPage> createState() => _NoticeListPageState();
}

class _NoticeListPageState extends ConsumerState<NoticeListPage> {
  /// 是否处于多选管理模式
  bool _selecting = false;
  bool _opening = false;

  /// 已勾选的通知 id
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialFilter != null) {
      // 放到帧后写 provider：build 期改依赖会触发「修改监听中的 provider」断言。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(noticeFilterProvider.notifier).state = widget.initialFilter!;
        }
      });
    }
  }

  void _enterSelection([String? initialId]) {
    if (_opening) return;
    setState(() {
      _selecting = true;
      _selected.clear();
      if (initialId != null) _selected.add(initialId);
    });
  }

  /// 长按分组卡进入选择模式：整组默认勾选（选择按组粒度操作）。
  void _enterSelectionWithIds(Set<String> ids) {
    if (_opening) return;
    setState(() {
      _selecting = true;
      _selected.clear();
      _selected.addAll(ids);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  /// 批量删除：二次确认 → 调后端 → 刷新列表/角标
  Future<void> _deleteSelected() async {
    final count = _selected.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const Text('删除通知'),
        content: Text('确定删除选中的 $count 条通知吗？删除后将从你的通知列表移除。'),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final deleted = await deleteNotices(ref, _selected.toList());
    if (!mounted) return;
    _exitSelection();
    context.appSuccess('已删除 $deleted 条通知');
  }

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(noticeListProvider);
    final filter = ref.watch(noticeFilterProvider);

    // 分类与卡片内容共左缘，动作在宽屏靠右；窄屏或大字号时换行，避免相互遮挡。
    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s12,
            bottom: UtenSpacing.s8,
          ),
          child: UtenFilterToolbar<NoticeFilter>(
            autoSelectBadge: false,
            selected: {filter},
            onSelectionChanged: (value) =>
                ref.read(noticeFilterProvider.notifier).state = value,
            segments: const [
              UtenFilterSegment(value: NoticeFilter.all, label: '全部'),
              UtenFilterSegment(value: NoticeFilter.unread, label: '未读'),
              // 重要 = 人事序列部门发布且未读（2026-09-28 用户口径）。
              UtenFilterSegment(value: NoticeFilter.important, label: '重要'),
            ],
            trailing: Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: UtenSpacing.s4,
              runSpacing: UtenSpacing.s4,
              children: [
                // 个人通知弹窗开关（V833/ADR-172）：设置全部弹窗类别的开与关。
                IconButton(
                  tooltip: '通知设置',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => showNoticePopupSettingsDialog(context),
                  icon: const Icon(Icons.tune_rounded, size: 20),
                ),
                if (_selecting) ...[
                  UtenButton(
                    type: UtenButtonType.ghost,
                    size: UtenButtonSize.small,
                    onPressed: () {
                      final notices = list.value ?? const <Notice>[];
                      setState(() {
                        _selected
                          ..clear()
                          ..addAll(notices.map((n) => n.id));
                      });
                    },
                    child: const Text('全选'),
                  ),
                  UtenButton(
                    type: UtenButtonType.ghost,
                    size: UtenButtonSize.small,
                    onPressed: _exitSelection,
                    child: const Text('退出管理'),
                  ),
                ] else ...[
                  UtenButton(
                    type: UtenButtonType.secondary,
                    size: UtenButtonSize.small,
                    icon: Icons.checklist_rounded,
                    onPressed: _enterSelection,
                    child: const Text('管理'),
                  ),
                  UtenActionButton(
                    type: UtenActionButtonType.ghost,
                    size: UtenActionButtonSize.small,
                    label: const Text('全部已读'),
                    onAction: () async {
                      await markAllNoticeRead(ref);
                      if (context.mounted) {
                        context.appSuccess('全部已读');
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: () => ref.read(noticeListProvider.notifier).refresh(),
            child: list.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(
                message: humanErrorMessage(e) ?? '通知加载失败，请稍后重试',
                onAction: () => ref.invalidate(noticeListProvider),
              ),
              data: (notices) {
                if (notices.isEmpty) {
                  return ListView(
                    children: [
                      const SizedBox(height: UtenSpacing.s48),
                      UtenEmpty(
                        icon: Icons.notifications_none_rounded,
                        message: switch (filter) {
                          // 默认段是「未读」：空了说明都处理完了，指引去「全部」翻历史。
                          NoticeFilter.unread => '没有未读通知，切换「全部」可查看历史',
                          NoticeFilter.important => '暂无重要通知',
                          NoticeFilter.all => '暂无通知',
                        },
                      ),
                    ],
                  );
                }
                // 同一业务对象（订单/报价/领料单…）的相关通知叠成一组；
                // 组的位置沿用服务端序（置顶优先、发布时间倒序）。
                final groups = groupNotices(notices);
                return UtenPagedGrid(
                  // 通知是公司广播型累积数据（无时间窗/上限），客户端按页切片：
                  // 恒只构建当页 ~20 张卡片，避免一次性铺全部致卡顿。
                  // 数据真正海量时改服务端 page/size 真分页。
                  items: groups,
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: EdgeInsets.only(
                    top: UtenSpacing.s16,
                    // 底部留白：compact 悬浮胶囊避让（滚到底末卡越过胶囊）+
                    //（选择模式时）多选操作条。
                    bottom: _selecting
                        ? 160
                        : math.max(
                            96,
                            UtenCapsuleNavScope.occlusionOf(context),
                          ),
                  ),
                  itemBuilder: (context, i, _) {
                    final group = groups[i];
                    if (group.isSingle) {
                      final notice = group.notices.first;
                      return NoticeCard(
                        key: ValueKey(notice.id),
                        notice: notice,
                        selecting: _selecting,
                        checked: _selected.contains(notice.id),
                        onLongPress: () {
                          if (!_selecting) _enterSelection(notice.id);
                        },
                        onAcknowledge: () => acknowledgeNotice(ref, notice.id),
                        onTap: () async {
                          if (_selecting) {
                            _toggle(notice.id);
                            return;
                          }
                          if (_opening) return;
                          _opening = true;
                          try {
                            if (!notice.isRead) {
                              await markNoticeRead(ref, notice.id);
                            }
                            if (!mounted) return;
                            await showNoticeDetailDialog(
                              this.context,
                              noticeId: notice.id,
                            );
                          } catch (error) {
                            if (mounted) {
                              this.context.appError(
                                humanErrorMessage(error) ?? '通知打开失败，请重试',
                              );
                            }
                          } finally {
                            _opening = false;
                          }
                          // 详情弹窗关闭后刷新列表：用户可能在详情里标记完成/已读，
                          // 列表与未读角标需同步，避免停留在旧状态。
                          if (mounted) ref.invalidate(noticeListProvider);
                        },
                      );
                    }
                    return Builder(
                      builder: (cardContext) => NoticeStackCard(
                        key: ValueKey(group.key),
                        group: group,
                        selecting: _selecting,
                        checked: group.ids.every(_selected.contains),
                        onLongPress: () {
                          if (!_selecting) _enterSelectionWithIds(group.ids);
                        },
                        onTap: () async {
                          if (_selecting) {
                            // 组粒度切换：全选过则整组取消，否则整组勾上。
                            setState(() {
                              final allSelected = group.ids.every(
                                _selected.contains,
                              );
                              allSelected
                                  ? _selected.removeAll(group.ids)
                                  : _selected.addAll(group.ids);
                            });
                            return;
                          }
                          if (_opening) return;
                          _opening = true;
                          final box = cardContext.findRenderObject();
                          final overlay = Navigator.of(
                            this.context,
                            rootNavigator: true,
                          ).overlay?.context.findRenderObject();
                          final originRect =
                              box is RenderBox && overlay is RenderBox
                              ? box.localToGlobal(
                                      Offset.zero,
                                      ancestor: overlay,
                                    ) &
                                    box.size
                              : null;
                          try {
                            await showNoticeGroupDialog(
                              this.context,
                              group: group,
                              originRect: originRect,
                            );
                          } finally {
                            _opening = false;
                          }
                          // 组弹窗内可能已置读/全部已读，回到列表同步刷新。
                          if (mounted) ref.invalidate(noticeListProvider);
                        },
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      body: body,
      // 多选操作：2026-09-14 UI 统一口径——吸底操作条改右下悬浮组，
      // 「已选 N」用全站标准胶囊，删除按钮统一 large。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _selecting
          ? UtenFloatingActionGroup(
              children: [
                UtenSelectionSummaryPill(count: _selected.length),
                // 未选中时视觉禁用（UtenActionButton 无 disabled 参数，
                // 用 Opacity + IgnorePointer 包一层）
                Opacity(
                  opacity: _selected.isEmpty ? 0.5 : 1,
                  child: IgnorePointer(
                    ignoring: _selected.isEmpty,
                    child: UtenActionButton(
                      type: UtenActionButtonType.danger,
                      size: UtenActionButtonSize.large,
                      icon: Icons.delete_outline_rounded,
                      label: const Text('删除'),
                      loadingLabel: const Text('删除中…'),
                      onAction: _deleteSelected,
                    ),
                  ),
                ),
              ],
            )
          : null,
    );
  }
}
