// MyProfileChangesPage - 员工自查：我的修改申请
// 文档：docs/03-页面/我的页.md（§我的修改申请）
//
// 2026-09-09 表格化改版：卡片网格 → MasterDataTableView（列对齐 + 分页）。
// 列：变更字段/项数/状态/提交时间/审核信息（原卡片字段全部保留；列表接口不含
// 逐字段旧→新值，旧→新对比在双击行打开的差异弹窗里）。顶部 UtenSegmentedFilter
// 分段（全部/待审/已通过/已驳回）保留；无多选（本人只能撤销自己的待审批次，
// 逐条语义，不做批量）。行双击开差异弹窗；行右键/长按菜单提供「撤销申请」
//（仅待审段）与「查看差异」。
// 2026-09-10 表头筛选：「状态」列筛选桶 = 分段可选状态集（待审/已生效/已驳回），
// 选中即切到对应分段并回第 1 页（下推后端 status 参数，非页内裁剪）。
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/profile_change_request.dart';
import '../providers/profile_change_providers.dart';
import '../repositories/profile_change_repository.dart';
import '../widgets/profile_change_diff_row.dart';

class MyProfileChangesPage extends ConsumerStatefulWidget {
  const MyProfileChangesPage({super.key});

  @override
  ConsumerState<MyProfileChangesPage> createState() =>
      _MyProfileChangesPageState();
}

class _MyProfileChangesPageState extends ConsumerState<MyProfileChangesPage> {
  String? _status; // null = 全部
  int _page = 1; // 当前页（服务端真分页：翻页/换筛选都从后端按页拉取）
  final List<UtenSegment<String?>> _segments = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.invalidate(myProfileChangesProvider);
    });
  }

  /// 「状态」列筛选桶：与顶部分段同一状态集（value = 后端状态码）。
  /// 桶不带计数（按页拉取，无全量计数口径）。
  List<MasterFacetBucket> _statusFacets(AppLocalizations l10n) => [
    MasterFacetBucket(
      value: 'pending',
      count: 0,
      label: l10n.profileChangeFilterPending,
    ),
    MasterFacetBucket(
      value: 'applied',
      count: 0,
      label: l10n.profileChangeFilterApplied,
    ),
    MasterFacetBucket(
      value: 'rejected',
      count: 0,
      label: l10n.profileChangeFilterRejected,
    ),
  ];

  /// 表头状态筛选 → 切到对应分段（下推后端 status）并回第 1 页；选「所有」= 全部段。
  void _onFilterChanged(String key, String? value) {
    if (key != 'status') return;
    setState(() {
      _status = value;
      _page = 1;
    });
  }

  Future<void> _openDetail(String batchId) {
    return showDialog<void>(
      context: context,
      builder: (_) => _MyBatchDetailDialog(batchId: batchId),
    );
  }

  /// 撤销待审批次（原卡片「撤销」按钮能力移入行菜单）。
  Future<void> _cancel(String batchId) async {
    final l10n = AppLocalizations.of(context);
    try {
      await ref.read(profileChangeRepositoryProvider).cancel(batchId);
      if (!mounted) return;
      ref.invalidate(myProfileChangesProvider);
      context.appSuccess(l10n.profileChangeCancelledByMe);
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.profileChangeSubmitFailed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    _segments
      ..clear()
      ..addAll([
        UtenSegment(value: null, label: l10n.profileChangeFilterAll),
        UtenSegment(value: 'pending', label: l10n.profileChangeFilterPending),
        UtenSegment(value: 'applied', label: l10n.profileChangeFilterApplied),
        UtenSegment(value: 'rejected', label: l10n.profileChangeFilterRejected),
      ]);

    final async = ref.watch(
      myProfileChangesProvider((status: _status, page: _page)),
    );

    Widget body = Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
          child: UtenSegmentedFilter<String?>(
            segments: _segments,
            selected: _status,
            onChanged: (v) => setState(() {
              _status = v;
              _page = 1; // 换筛选回到第 1 页
            }),
          ),
        ),
        Expanded(child: _buildBody(l10n, async)),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.profileChangeListTitle,
        // go 进入（非 push），栈被替换；返回显式回"我的"页
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.profile),
        ),
      ),
      body: body,
    );
  }

  Widget _buildBody(
    AppLocalizations l10n,
    AsyncValue<ProfileChangePage<MyProfileChangeListItem>> async,
  ) {
    return async.when(
      data: (page) => RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(myProfileChangesProvider);
          await ref.read(
            myProfileChangesProvider((status: _status, page: _page)).future,
          );
        },
        child: MasterDataTableView<MyProfileChangeListItem>(
          key: const Key('my-profile-changes-table'),
          columns: _columns(l10n),
          items: page.items,
          facets: {'status': _statusFacets(l10n)},
          nullCounts: const {},
          filters: {'status': _status},
          onFilterChanged: _onFilterChanged,
          // 双击行打开本批旧→新差异弹窗（保留原卡片「查看差异」能力）。
          onRowTap: (item) => _openDetail(item.batchId),
          // 行右键/长按菜单：撤销申请（仅待审批）+ 查看差异。
          rowMenuBuilder: (item) => [
            UtenMenuItem(
              label: l10n.profileChangeDiffTitle,
              icon: Icons.difference_outlined,
              onTap: () => _openDetail(item.batchId),
            ),
            if (item.status == ProfileChangeStatus.pending) ...[
              const UtenMenuDivider(),
              UtenMenuItem(
                label: l10n.profileChangeCancel,
                icon: Icons.undo_rounded,
                destructive: true,
                onTap: () => _cancel(item.batchId),
              ),
            ],
          ],
          emptyMessage: l10n.profileChangeListEmpty,
          currentPage: page.page,
          totalPages: page.totalPages,
          onPageChange: (p) => setState(() => _page = p),
        ),
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => UtenEmpty.error(
        message: e is ApiException ? e.message : l10n.commonError,
        actionLabel: l10n.commonRetry,
        onAction: () => ref.invalidate(myProfileChangesProvider),
      ),
    );
  }

  List<MasterColumnDef<MyProfileChangeListItem>> _columns(
    AppLocalizations l10n,
  ) => [
    MasterColumnDef(
      key: 'fields',
      label: '变更字段',
      width: 320,
      info: '本批修改涉及的档案字段（顿号连接）；双击行可查看逐字段旧→新值对比。',
      value: (item) => item.fieldLabels.join('、'),
    ),
    MasterColumnDef(
      key: 'itemCount',
      label: '项数',
      width: 80,
      type: 'number',
      value: (item) => item.itemCount.toString(),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 90,
      info: '表头筛选与顶部分段同一口径：选中状态即切到对应分段并回第 1 页。',
      value: (item) => _statusLabel(l10n, item.status),
    ),
    MasterColumnDef(
      key: 'submittedAt',
      label: '提交时间',
      width: 150,
      type: 'date',
      value: (item) => _formatTime(item.submittedAt),
    ),
    MasterColumnDef(
      key: 'reviewComment',
      label: '审核信息',
      width: 260,
      info: 'HR 审核意见（驳回原因等）；未审核或无意见时留空。',
      value: (item) =>
          (item.reviewComment == null || item.reviewComment!.isEmpty)
          ? null
          : item.reviewComment,
    ),
  ];
}

/// 详情弹窗（按 batchId 拉一次）。
class _MyBatchDetailDialog extends ConsumerWidget {
  const _MyBatchDetailDialog({required this.batchId});
  final String batchId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final async = ref.watch(myProfileChangeDetailProvider(batchId));
    // 弹窗文字可框选复制（准则 §3.4：弹窗独立路由自带局部 region）。
    return SelectionArea(
      child: Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600, maxHeight: 700),
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l10n.profileChangeDiffTitle,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Flexible(
                  child: async.when(
                    data: (batch) => SingleChildScrollView(
                      child: Column(
                        children: [
                          for (final item in batch.items)
                            ProfileChangeDiffRow(
                              item: item,
                              showStatusBadge: true,
                            ),
                        ],
                      ),
                    ),
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) =>
                        Text(e is ApiException ? e.message : l10n.commonError),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Align(
                  alignment: Alignment.centerRight,
                  child: UtenButton(
                    type: UtenButtonType.ghost,
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.profileChangeCancel2),
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

String _statusLabel(AppLocalizations l10n, ProfileChangeStatus s) {
  switch (s) {
    case ProfileChangeStatus.pending:
      return l10n.profileChangeStatusPending;
    case ProfileChangeStatus.applied:
      return l10n.profileChangeStatusApplied;
    case ProfileChangeStatus.approved:
      return l10n.profileChangeStatusApproved;
    case ProfileChangeStatus.rejected:
      return l10n.profileChangeStatusRejected;
    case ProfileChangeStatus.cancelled:
      return l10n.profileChangeStatusCancelled;
  }
}

String _formatTime(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
