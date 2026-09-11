// 我的访客(被访人)：确认/拒绝转给自己的访客申请。
//
// 2026-09-09 表格化改版：卡片 → MasterDataTableView（列对齐 + 分页）。
// 列：访客姓名/公司/事由/计划到访/状态；「确认接待/拒绝」保留为行菜单
//（右击/长按 rowMenuBuilder）。
// 2026-09-10 表头筛选 + 批量确认（审计 A2-personal-lists）：
//   * 「状态」列筛选桶 = 后端 as-host 支持的状态集（待我确认/已转 HR/已批准/已拒绝），
//     选中后下推 status 参数并回第 1 页（非页内裁剪）；默认「待我确认」；
//   * 「待我确认」口径下开多选 + 右下角「批量确认接待(N)」——逐条复用
//     hostConfirm(true) 单条 API，非待我确认的行前端跳过并计入提示，失败聚合提示。
//
// 响应式：compact 自套 UtenContentContainer 收敛；medium+ 外壳已收敛；
// 窄屏表格横向滚动即可。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../visitor/models/visitor_application.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';
import '../providers/visitor_approval_providers.dart';
import '../providers/visitor_pending_count_provider.dart';

/// 单次批量上限：逐条循环单条 API，超过则提示分批（无后端批量端点）。
const int kMyVisitorsBatchLimit = 50;

class MyVisitorsPage extends ConsumerStatefulWidget {
  const MyVisitorsPage({super.key});

  @override
  ConsumerState<MyVisitorsPage> createState() => _MyVisitorsPageState();
}

class _MyVisitorsPageState extends ConsumerState<MyVisitorsPage> {
  int _page = 1;

  /// 表头「状态」筛选（null = 后端默认 hostReviewing「待我确认」）。
  String? _status;

  /// 多选：申请 id（仅「待我确认」口径开放）。换筛选清空。
  Set<String> _selectedIds = {};

  /// 批量确认进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  /// 「待我确认」口径（默认或显式选中 hostReviewing）才开多选批量。
  bool get _isHostReviewing => _status == null || _status == 'hostReviewing';

  VisitorHostQuery get _query => (status: _status, page: _page);

  Future<void> _confirm(
    BuildContext context,
    VisitorApplication app,
    bool confirmed,
    AppLocalizations l10n,
  ) async {
    try {
      await ref
          .read(visitorStaffRepositoryProvider)
          .hostConfirm(app.id, confirmed: confirmed);
      if (!context.mounted) return;
      setState(() => _page = 1);
      ref.invalidate(myAsHostProvider);
      // 确认后回到 pending（HR 待办）或 rejected，两个徽章都要刷新
      ref.read(visitorHostPendingCountProvider.notifier).refresh();
      ref.read(visitorPendingCountProvider.notifier).refresh();
      context.appSuccess(confirmed ? '已确认接待，申请已转回 HR 审批' : '已拒绝接待');
    } on ApiException catch (e) {
      if (context.mounted) {
        context.appApiError(e, fallback: l10n.commonError);
      }
    } catch (_) {
      if (context.mounted) context.appError(l10n.commonError);
    }
  }

  /// 表头筛选：状态 → 下推后端 status 并回第 1 页；换口径清空选中。
  void _onFilterChanged(String key, String? value) {
    if (key != 'status') return;
    setState(() {
      _status = value;
      _page = 1;
      _selectedIds = {};
    });
  }

  /// 「状态」列筛选桶：后端 as-host 支持的状态集（value = 状态码）。
  /// 桶不带计数（按页拉取，无全量计数口径）。
  List<MasterFacetBucket> _statusFacets(AppLocalizations l10n) => [
    for (final status in const [
      VisitorApplicationStatus.hostReviewing,
      VisitorApplicationStatus.pending,
      VisitorApplicationStatus.approved,
      VisitorApplicationStatus.rejected,
    ])
      MasterFacetBucket(
        value: status.name,
        count: 0,
        label: visitorStatusLabel(status, l10n),
      ),
  ];

  /// 批量确认接待：逐条复用 hostConfirm(true) 单条 API（服务端逐条校验接待人本人 +
  /// 状态守卫）；非「待我确认」的行前端跳过并计入提示，失败原因聚合提示。
  Future<void> _batchConfirm(
    Set<String> ids,
    List<VisitorApplication> pageItems,
  ) async {
    if (_batchBusy || ids.isEmpty) return;
    final statusById = {for (final app in pageItems) app.id: app.status};
    final confirmable = ids
        .where(
          (id) =>
              statusById[id] == null ||
              statusById[id] == VisitorApplicationStatus.hostReviewing,
        )
        .toSet();
    final skipped = ids.length - confirmable.length;
    if (confirmable.isEmpty) {
      context.appError('所选申请均不在「待我确认」状态，无需确认');
      return;
    }
    if (confirmable.length > kMyVisitorsBatchLimit) {
      context.appError(
        '单次最多批量处理 $kMyVisitorsBatchLimit 条，请分批操作（当前 ${confirmable.length} 条）',
      );
      return;
    }
    final l10n = AppLocalizations.of(context);
    final count = confirmable.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('批量确认接待($count)'),
        content: SizedBox(
          width: 440,
          child: Text(
            '将逐条确认接待所选 $count 位访客，确认后申请转回 HR 等待最终批准。'
            '${skipped > 0 ? '（另有 $skipped 条不在「待我确认」状态，已跳过）' : ''}',
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('确认接待'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _batchBusy = true);
    final repo = ref.read(visitorStaffRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final id in confirmable) {
      try {
        await repo.hostConfirm(id, confirmed: true);
        okCount++;
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        failures.add(l10n.commonError);
      }
    }
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectedIds = {};
      _page = 1;
    });
    if (okCount > 0) {
      context.appSuccess(
        '已确认接待 $okCount 位访客'
        '${failures.isNotEmpty ? '，${failures.length} 条失败' : ''}'
        '${skipped > 0 ? '，$skipped 条已跳过' : ''}',
      );
    }
    if (failures.isNotEmpty) {
      context.appError('批量确认未全部完成：${failures.first}');
    }
    ref.invalidate(myAsHostProvider);
    ref.read(visitorHostPendingCountProvider.notifier).refresh();
    ref.read(visitorPendingCountProvider.notifier).refresh();
  }

  List<Widget> _batchActions(
    BuildContext context,
    Set<String> selectedIds,
    List<VisitorApplication> pageItems,
  ) => [
    UtenButton(
      key: const Key('my-visitors-batch-confirm'),
      type: UtenButtonType.danger,
      size: UtenButtonSize.large,
      icon: Icons.check_circle_outline_rounded,
      isLoading: _batchBusy,
      onPressed: selectedIds.isNotEmpty && !_batchBusy
          ? () => _batchConfirm(Set<String>.of(selectedIds), pageItems)
          : null,
      child: Text('批量确认接待(${selectedIds.length})'),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final list = ref.watch(myAsHostProvider(_query));
    return Scaffold(
      appBar: UtenAppBar(title: l10n.myVisitorsTitle, showBackButton: true),
      body: list.when(
        loading: () => const UtenSkeletonList(itemCount: 4),
        error: (e, _) => UtenEmpty.error(
          message: '$e',
          actionLabel: l10n.commonRetry,
          onAction: () => ref.invalidate(myAsHostProvider(_query)),
        ),
        data: (page) {
          final isCompact = context.breakpoint.isCompact;
          Widget body = RefreshIndicator(
            onRefresh: () async => ref.invalidate(myAsHostProvider(_query)),
            child: MasterDataTableView<VisitorApplication>(
              key: const Key('my-visitors-table'),
              columns: _columns(l10n),
              items: page.items,
              facets: {'status': _statusFacets(l10n)},
              nullCounts: const {},
              filters: {'status': _status ?? 'hostReviewing'},
              onFilterChanged: _onFilterChanged,
              // 「待我确认」口径开多选 + 悬浮批量确认接待；其余口径只读浏览。
              selectable: _isHostReviewing,
              idOf: (app) => app.id,
              selectedIds: _selectedIds,
              onSelectedIdsChanged: (next) =>
                  setState(() => _selectedIds = next),
              batchActionsBuilder: _isHostReviewing
                  ? (context, ids) => _batchActions(context, ids, page.items)
                  : null,
              // 确认接待/拒绝保留为行菜单（右击/长按）；无行详情路由。
              rowMenuBuilder: (app) => [
                UtenMenuItem(
                  label: l10n.myVisitorsConfirm,
                  icon: Icons.check_circle_outline_rounded,
                  onTap: () => _confirm(context, app, true, l10n),
                ),
                UtenMenuItem(
                  label: l10n.myVisitorsReject,
                  icon: Icons.cancel_outlined,
                  destructive: true,
                  onTap: () => _confirm(context, app, false, l10n),
                ),
              ],
              emptyMessage: l10n.myVisitorsEmpty,
              // 被访人待确认是个人 + 瞬态（status=hostReviewing，确认后即脱离），
              // 常态 0-3 条；仍接分页以防极端堆积。
              currentPage: page.page,
              totalPages: page.totalPages,
              onPageChange: (p) => setState(() => _page = p),
            ),
          );
          // compact 自套收敛；selectable:false——访客待办计数轮询（结构性闪现）
          // 与拖选并发有 CME 风险（准则 §3.4，用户口径：轮询页不包）。
          if (isCompact) {
            body = UtenContentContainer(selectable: false, child: body);
          }
          return body;
        },
      ),
    );
  }

  List<MasterColumnDef<VisitorApplication>> _columns(AppLocalizations l10n) => [
    MasterColumnDef(
      key: 'visitorName',
      label: '访客姓名',
      width: 130,
      value: (app) => app.visitorName,
    ),
    MasterColumnDef(
      key: 'company',
      label: '公司',
      width: 170,
      value: (app) => app.company,
    ),
    MasterColumnDef(
      key: 'visitPurpose',
      label: '事由',
      width: 260,
      value: (app) => app.visitPurpose,
    ),
    MasterColumnDef(
      key: 'plannedVisitAt',
      label: '计划到访',
      width: 180,
      type: 'date',
      value: (app) => fmtDateTime(app.plannedVisitAt),
    ),
    MasterColumnDef(
      key: 'status',
      label: '状态',
      width: 110,
      info: '默认只看「待我确认」；表头筛选可切到已转 HR / 已批准 / 已拒绝（下推后端）。',
      value: (app) => visitorStatusLabel(app.status, l10n),
    ),
  ];
}
