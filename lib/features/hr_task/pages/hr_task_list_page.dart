// HR 工作台子页面：按类型展示任务列表（转正办理/生日关怀/入职周年/新近入职）。
//
// 2026-09-10 表格化 + 多选批量（审计 A2-hr-task-center）：宽屏主体由 ListView+Card
// 改为 MasterDataTableView<HrTaskItem>（key 'hr-task-table'）——列 工号/姓名/部门/
// 岗位/日期/天数/认领/已祝福（已祝福仅庆典类）；表头筛选桶客户端聚合（部门/区间/
// 认领状态，数据本就是服务端一次性下发的全量 summary，无分页，故不下推后端）；
// 行右键/长按菜单保留 认领/释放/接管/查看档案（转正类加「登记转正」、今日庆典加
// 「送祝福」，逐行能力一条不少）；多选 idOf=employeeId：
//   * 转正类 →「批量登记转正(N)」：一次选日期，逐人 repo.confirm(id,date)，
//     409（已是正式员工）回退 repo.update(id,{'confirmedAt'})；被他人认领的行前端
//     跳过并计入失败（后端 confirm 无认领守卫）；门控 employee:confirm + employee:edit；
//   * 生日/周年 →「批量送祝福(N)」：publishCelebrationBatch(今日∩未祝福的选中人)，
//     门控 notice:publish；
//   * 新近入职 → 无批量动作（无可批量的状态动作），故不开多选。
//   批量后 hrTaskSummaryProvider.reloadSilently() 同步工作台/部门徽标。
// 窄屏（compact）保留卡片 + HrTaskTile（移动端手感，与其他任务中心一致）。
// 文档：docs/03-页面/HR任务中心.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/master_facet.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../notice/models/notice.dart';
import '../../notice/providers/notice_providers.dart';
import '../models/hr_task_summary.dart';
import '../providers/hr_task_summary_provider.dart';
import '../repositories/hr_task_repository.dart';
import '../widgets/hr_task_widgets.dart';

/// 单次批量上限：逐人循环单条 API，超过则提示分批（无后端批量端点）。
const int kHrTaskBatchLimit = 50;

/// 任务时间区间（表头「区间」筛选桶）。
enum HrTaskWindow {
  overdue('逾期'),
  today('今日'),
  upcoming('即将');

  const HrTaskWindow(this.label);
  final String label;
}

/// 条目所属区间：转正按服务端三段列表判定；庆典按「今日」列表判定；
/// 新近入职按 days==0（今日入职）判定。
HrTaskWindow hrTaskWindowOf(HrTaskSummary s, HrTaskType type, HrTaskItem item) {
  switch (type) {
    case HrTaskType.confirm:
      if (s.confirmOverdue.any((i) => i.employeeId == item.employeeId)) {
        return HrTaskWindow.overdue;
      }
      if (s.confirmToday.any((i) => i.employeeId == item.employeeId)) {
        return HrTaskWindow.today;
      }
      return HrTaskWindow.upcoming;
    case HrTaskType.birthday:
      return hrTaskIsToday(s, type, item)
          ? HrTaskWindow.today
          : HrTaskWindow.upcoming;
    case HrTaskType.anniversary:
      return HrTaskWindow.today;
    case HrTaskType.newhire:
      return item.days == 0 ? HrTaskWindow.today : HrTaskWindow.upcoming;
  }
}

/// 认领状态（表头「认领」筛选桶）。
enum HrTaskClaimState {
  free('未认领'),
  mine('我处理中'),
  others('他人处理中');

  const HrTaskClaimState(this.label);
  final String label;
}

HrTaskClaimState hrTaskClaimStateOf(HrTaskItem item) {
  if (item.claimedByName == null) return HrTaskClaimState.free;
  return item.claimedByMe ? HrTaskClaimState.mine : HrTaskClaimState.others;
}

class HrTaskListPage extends ConsumerStatefulWidget {
  const HrTaskListPage({super.key, required this.type});

  final HrTaskType type;

  @override
  ConsumerState<HrTaskListPage> createState() => _HrTaskListPageState();
}

class _HrTaskListPageState extends ConsumerState<HrTaskListPage> {
  /// 表头筛选（部门/区间/认领状态）：桶与裁剪都在客户端——summary 是一次性全量
  /// 下发、无分页，不存在「命中行落在其他页」的问题。
  Map<String, String?> _filters = {};

  /// 多选：employeeId（同一类型内唯一）。
  Set<String> _selectedIds = {};

  /// 批量动作进行中（防并发 + 按钮加载态）。
  bool _batchBusy = false;

  HrTaskType get _type => widget.type;

  bool get _isCelebration =>
      _type == HrTaskType.birthday || _type == HrTaskType.anniversary;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(hrTaskSummaryProvider);
    final perms = ref.watch(currentPermissionsProvider);
    final isSuperAdmin = ref.watch(isSuperAdminProvider);
    final canPublish = isSuperAdmin || perms.contains(Perm.noticePublish);
    // 批量登记转正会走 confirm，失败回退 PUT 员工档案 → 两个权限都要有。
    final canBatchConfirm =
        perms.contains(Perm.employeeConfirm) &&
        perms.contains(Perm.employeeEdit);

    Widget body = async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => UtenEmpty.error(
        message: '加载失败，请稍后重试',
        actionLabel: '重试',
        onAction: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
      ),
      data: (s) {
        final items = hrTaskItemsOf(s, _type);
        // 一键祝福只针对「今日」在册且本类型本年未祝福者。
        // 注意：生日列表 hrTaskItemsOf 把 birthdayToday 与未来 30 天的
        // birthdayUpcoming 合并展示了，不能拿合并后的 items 整列发，否则会把
        // 还没到的生日也提前祝福掉。这里只取今日列表（周年列表本身就是今日全量）。
        final todayItems = switch (_type) {
          HrTaskType.birthday => s.birthdayToday,
          HrTaskType.anniversary => s.anniversaryToday,
          _ => const <HrTaskItem>[],
        };
        final toBless = _isCelebration
            ? todayItems.where((i) => !i.blessed).toList()
            : <HrTaskItem>[];
        final visible = _applyFilters(s, items);
        final isCompact = context.breakpoint.isCompact;
        return RefreshIndicator(
          onRefresh: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
          child: isCompact
              ? _mobileList(s, items, toBless, canPublish)
              : _desktopTable(
                  s,
                  items,
                  visible,
                  toBless,
                  canPublish: canPublish,
                  canBatchConfirm: canBatchConfirm,
                ),
        );
      },
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: _type.title,
        showBackButton: true,
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.read(hrTaskSummaryProvider.notifier).refresh(),
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: body,
    );
  }

  // ═══════════════════════ 宽屏：MasterDataTableView ═══════════════════════

  Widget _desktopTable(
    HrTaskSummary s,
    List<HrTaskItem> all,
    List<HrTaskItem> visible,
    List<HrTaskItem> toBless, {
    required bool canPublish,
    required bool canBatchConfirm,
  }) {
    final showBatch = switch (_type) {
      HrTaskType.confirm => canBatchConfirm,
      HrTaskType.birthday || HrTaskType.anniversary => canPublish,
      HrTaskType.newhire => false,
    };
    return Column(
      children: [
        if (_type == HrTaskType.confirm)
          _hint(
            context,
            '试用期 ${s.probationMonths} 个月口径；'
            '被认领的事项显示「处理中」，他人不可重复操作。',
          ),
        if (_type == HrTaskType.confirm && s.unconfirmedLegacyCount > 0)
          _hint(
            context,
            '另有 ${s.unconfirmedLegacyCount} 名入职满一年的员工未登记转正日期，'
            '请在员工档案中补录。',
          ),
        Expanded(
          child: MasterDataTableView<HrTaskItem>(
            key: const Key('hr-task-table'),
            columns: _columns(s),
            items: visible,
            facets: _facetsOf(s, all),
            nullCounts: const {},
            filters: _filters,
            onFilterChanged: _onFilterChanged,
            selectable: showBatch,
            idOf: (item) => item.employeeId,
            selectedIds: _selectedIds,
            onSelectedIdsChanged: (next) => setState(() => _selectedIds = next),
            batchActionsBuilder: showBatch
                ? (context, ids) => _batchActions(ids, all, toBless)
                : null,
            // 点行 = 选中；行菜单（右键/长按）承载全部逐行操作。
            rowMenuBuilder: (item) => _rowMenu(s, item, canPublish: canPublish),
            emptyMessage: _type.emptyText,
          ),
        ),
      ],
    );
  }

  List<MasterColumnDef<HrTaskItem>> _columns(HrTaskSummary s) => [
    MasterColumnDef(
      key: 'code',
      label: '工号',
      width: 110,
      value: (item) => item.code,
    ),
    MasterColumnDef(
      key: 'name',
      label: '姓名',
      width: 120,
      value: (item) => item.name,
    ),
    MasterColumnDef(
      key: 'deptName',
      label: '部门',
      width: 150,
      value: (item) => item.deptName,
    ),
    MasterColumnDef(
      key: 'positionName',
      label: '岗位',
      width: 140,
      value: (item) => item.positionName,
    ),
    MasterColumnDef(
      key: 'date',
      label: _dateColumnLabel,
      width: 130,
      type: 'date',
      value: (item) => item.date,
    ),
    MasterColumnDef(
      key: 'days',
      label: _daysColumnLabel,
      width: 110,
      type: 'number',
      info: _daysColumnInfo,
      value: (item) => _daysText(s, item),
      cellBuilder: (context, item) {
        final overdue = hrTaskWindowOf(s, _type, item) == HrTaskWindow.overdue;
        final text = _daysText(s, item) ?? '';
        return Text(
          text,
          style: overdue
              ? TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                )
              : null,
          overflow: TextOverflow.ellipsis,
        );
      },
    ),
    MasterColumnDef(
      key: 'window',
      label: '区间',
      width: 90,
      info: '逾期 / 今日 / 即将——与服务端分组一致，用于表头快速筛选。',
      value: (item) => hrTaskWindowOf(s, _type, item).label,
    ),
    MasterColumnDef(
      key: 'claim',
      label: '认领',
      width: 200,
      info: '软认领（ADR-021）：显示认领人与租约到期时间；他人处理中的事项不可批量操作。',
      value: _claimText,
    ),
    if (_isCelebration)
      MasterColumnDef(
        key: 'blessed',
        label: '已祝福',
        width: 90,
        type: 'bool',
        info: '本类型本年是否已发布庆典祝福卡（已祝福者不计入徽标，也不会被批量重复祝福）。',
        value: (item) => item.blessed ? '已祝福' : null,
      ),
  ];

  String get _dateColumnLabel => switch (_type) {
    HrTaskType.confirm => '转正预计日',
    HrTaskType.birthday => '生日',
    HrTaskType.anniversary => '周年日',
    HrTaskType.newhire => '入职日',
  };

  String get _daysColumnLabel => switch (_type) {
    HrTaskType.confirm => '距转正(天)',
    HrTaskType.birthday => '距生日(天)',
    HrTaskType.anniversary => '入职年数',
    HrTaskType.newhire => '已入职(天)',
  };

  String get _daysColumnInfo => switch (_type) {
    HrTaskType.confirm => '距预计转正日的天数；已过期显示负数并标红（服务端 days 为逾期天数）。',
    HrTaskType.birthday => '距生日的天数；今日生日显示 0（服务端今日行的 days 存的是年龄）。',
    HrTaskType.anniversary => '今日满的入职年数。',
    HrTaskType.newhire => '入职至今的天数（今日入职 = 0）。',
  };

  /// 天数列文本：逾期取负数（列头已注明口径），今日取 0。
  String? _daysText(HrTaskSummary s, HrTaskItem item) {
    switch (_type) {
      case HrTaskType.confirm:
        return switch (hrTaskWindowOf(s, _type, item)) {
          HrTaskWindow.overdue => '-${item.days}',
          HrTaskWindow.today => '0',
          HrTaskWindow.upcoming => '${item.days}',
        };
      case HrTaskType.birthday:
        return hrTaskIsToday(s, _type, item) ? '0' : '${item.days}';
      case HrTaskType.anniversary:
      case HrTaskType.newhire:
        return '${item.days}';
    }
  }

  /// 认领列文本：认领人 + 租约到期（未认领留空）。
  String? _claimText(HrTaskItem item) {
    final name = item.claimedByName;
    if (name == null) return null;
    final who = item.claimedByMe ? '我' : name;
    final lease = _leaseText(item.claimLeaseUntil);
    return lease == null ? '$who 处理中' : '$who 处理中 · 租约至 $lease';
  }

  String? _leaseText(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    final parsed = DateTime.tryParse(iso);
    if (parsed == null) return null;
    final local = parsed.isUtc ? parsed.toLocal() : parsed;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }

  // ---- 表头筛选（客户端桶 + 客户端裁剪） -----------------------------------

  void _onFilterChanged(String key, String? value) {
    setState(() {
      final next = Map<String, String?>.from(_filters);
      if (value == null) {
        next.remove(key); // 选「所有」= 不筛
      } else {
        next[key] = value;
      }
      _filters = next;
      // 被筛掉的行不应留在选中集里（批量动作只对看得见的行负责）。
      _selectedIds = {};
    });
  }

  List<HrTaskItem> _applyFilters(HrTaskSummary s, List<HrTaskItem> items) {
    if (_filters.values.every((v) => v == null || v.isEmpty)) return items;
    final dept = _filters['deptName'];
    final window = _filters['window'];
    final claim = _filters['claim'];
    final blessed = _filters['blessed'];
    return items.where((item) {
      final deptOk =
          dept == null || dept.isEmpty || (item.deptName ?? '') == dept;
      final windowOk =
          window == null ||
          window.isEmpty ||
          hrTaskWindowOf(s, _type, item).label == window;
      final claimOk =
          claim == null ||
          claim.isEmpty ||
          hrTaskClaimStateOf(item).label == claim;
      final blessedOk =
          blessed == null ||
          blessed.isEmpty ||
          (item.blessed ? '已祝福' : '') == blessed;
      return deptOk && windowOk && claimOk && blessedOk;
    }).toList();
  }

  /// 筛选桶：部门/区间/认领状态（+庆典类的已祝福），全部从全量 items 聚合。
  Map<String, List<MasterFacetBucket>> _facetsOf(
    HrTaskSummary s,
    List<HrTaskItem> items,
  ) {
    List<MasterFacetBucket> bucketsOf(Iterable<String> texts) {
      final counts = <String, int>{};
      for (final text in texts) {
        if (text.isEmpty) continue;
        counts[text] = (counts[text] ?? 0) + 1;
      }
      final entries = counts.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return [
        for (final entry in entries)
          MasterFacetBucket(value: entry.key, count: entry.value),
      ];
    }

    return {
      'deptName': bucketsOf(items.map((item) => item.deptName ?? '')),
      'window': bucketsOf(
        items.map((item) => hrTaskWindowOf(s, _type, item).label),
      ),
      'claim': bucketsOf(items.map((item) => hrTaskClaimStateOf(item).label)),
      if (_isCelebration)
        'blessed': bucketsOf(items.map((item) => item.blessed ? '已祝福' : '')),
    };
  }

  // ---- 行菜单（逐行能力：查看档案 / 登记转正 / 送祝福 / 认领·释放·接管） ----

  List<UtenContextMenuEntry> _rowMenu(
    HrTaskSummary s,
    HrTaskItem item, {
    required bool canPublish,
  }) {
    final perms = ref.read(currentPermissionsProvider);
    final canConfirm = perms.contains(Perm.employeeConfirm);
    final canTakeover = perms.contains(Perm.employeeTaskTakeover);
    final blocked = item.claimedByOther;
    return [
      UtenMenuItem(
        label: '查看档案',
        icon: Icons.badge_outlined,
        onTap: () => context.push('/employee/${item.employeeId}'),
      ),
      if (_type == HrTaskType.confirm && canConfirm && !blocked)
        UtenMenuItem(
          label: '登记转正',
          icon: Icons.how_to_reg_outlined,
          onTap: () => showHrConfirmDialog(context, ref, item),
        ),
      if (_isCelebration &&
          canPublish &&
          hrTaskIsToday(s, _type, item) &&
          !item.blessed)
        UtenMenuItem(
          label: '送祝福',
          icon: _type.icon,
          onTap: () => context.push(
            '${RouteName.noticePublish}?type='
            '${_type == HrTaskType.birthday ? 'birthday' : 'anniversary'}'
            '&subject=${item.employeeId}',
          ),
        ),
      const UtenMenuDivider(),
      if (item.claimedByName == null)
        UtenMenuItem(
          label: '认领(标记为我在处理)',
          icon: Icons.person_add_alt_1_outlined,
          onTap: () => _runClaim(() async {
            await ref
                .read(hrTaskRepositoryProvider)
                .claim(_type.taskType, item.employeeId);
            return '已认领，其他同事将看到你正在处理';
          }),
        )
      else if (item.claimedByMe)
        UtenMenuItem(
          label: '释放(不再由我处理)',
          icon: Icons.person_remove_outlined,
          onTap: () => _runClaim(() async {
            await ref
                .read(hrTaskRepositoryProvider)
                .release(_type.taskType, item.employeeId);
            return '已释放';
          }),
        )
      else if (canTakeover)
        UtenMenuItem(
          label: '接管(转由我处理)',
          icon: Icons.swap_horizontal_circle_outlined,
          onTap: () => _runClaim(() async {
            await ref
                .read(hrTaskRepositoryProvider)
                .takeover(_type.taskType, item.employeeId);
            return '已接管，现在由你处理';
          }),
        ),
    ];
  }

  Future<void> _runClaim(Future<String> Function() action) async {
    try {
      final msg = await action();
      if (!mounted) return;
      context.appSuccess(msg);
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    } finally {
      // 操作后静默重取（无论成败，确保认领状态与最新一致）
      await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
    }
  }

  // ---- 批量动作 ------------------------------------------------------------

  List<Widget> _batchActions(
    Set<String> selectedIds,
    List<HrTaskItem> all,
    List<HrTaskItem> toBless,
  ) {
    final enabled = selectedIds.isNotEmpty && !_batchBusy;
    return switch (_type) {
      HrTaskType.confirm => [
        UtenButton(
          key: const Key('hr-task-batch-confirm'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.how_to_reg_outlined,
          isLoading: _batchBusy,
          onPressed: enabled
              ? () => _batchConfirm(Set<String>.of(selectedIds), all)
              : null,
          child: Text('批量登记转正(${selectedIds.length})'),
        ),
      ],
      HrTaskType.birthday || HrTaskType.anniversary => [
        UtenButton(
          key: const Key('hr-task-batch-bless'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: _type.icon,
          isLoading: _batchBusy,
          onPressed: enabled
              ? () => _batchBless(Set<String>.of(selectedIds), toBless)
              : null,
          child: Text('批量送祝福(${selectedIds.length})'),
        ),
      ],
      HrTaskType.newhire => const <Widget>[],
    };
  }

  /// 批量登记转正：一次选日期，逐人 confirm；409 回退补登 confirmedAt。
  /// 被他人认领的行不发请求（后端 confirm 无认领守卫，前端兜住重复操作），计入失败。
  Future<void> _batchConfirm(Set<String> ids, List<HrTaskItem> all) async {
    if (_batchBusy || ids.isEmpty) return;
    if (ids.length > kHrTaskBatchLimit) {
      context.appError(
        '单次最多批量处理 $kHrTaskBatchLimit 人，请分批操作（当前 ${ids.length} 人）',
      );
      return;
    }
    final byId = {for (final item in all) item.employeeId: item};
    final blocked = ids
        .where((id) => byId[id]?.claimedByOther ?? false)
        .toSet();
    final targets = ids.difference(blocked);
    if (targets.isEmpty) {
      context.appError('所选事项均被他人认领处理中，未执行');
      return;
    }
    final date = await _pickConfirmDate(targets.length);
    if (date == null || !mounted) return;

    setState(() => _batchBusy = true);
    final repo = ref.read(employeeRepositoryProvider);
    var okCount = 0;
    final failures = <String>[];
    for (final id in targets) {
      final name = byId[id]?.name ?? id;
      try {
        try {
          await repo.confirm(id, confirmedDate: date);
        } on ApiException catch (e) {
          if (e.code == 'CONFLICT') {
            // 非试用期（已是正式员工但未登记转正日期）→ 补登
            await repo.update(id, {'confirmedAt': date});
          } else {
            rethrow;
          }
        }
        okCount++;
      } on ApiException catch (e) {
        failures.add('$name：${e.message}');
      } catch (_) {
        failures.add('$name：操作失败');
      }
    }
    final blockedNames = [for (final id in blocked) byId[id]?.name ?? id];
    if (!mounted) return;
    setState(() {
      _batchBusy = false;
      _selectedIds = {};
    });
    if (okCount > 0) {
      context.appSuccess('已登记 $okCount 人的转正日期 $date');
    }
    final allFailures = [
      ...failures,
      for (final name in blockedNames) '$name：他人认领处理中，已跳过',
    ];
    if (allFailures.isNotEmpty) {
      context.appError('${allFailures.length} 人未完成：${allFailures.first}');
    }
    await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
  }

  /// 转正日期选择（整批一个日期，默认今天；不可选未来）。
  Future<String?> _pickConfirmDate(int count) async {
    final today = DateTime.now();
    DateTime selected = today;
    String two(int n) => n.toString().padLeft(2, '0');
    String fmt(DateTime d) => '${d.year}-${two(d.month)}-${two(d.day)}';
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text('批量登记转正($count 人)'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '所选 $count 人将使用同一个实际转正日期（默认今天）。'
                  '试用期员工转为在职；已是正式员工的补登转正日期。',
                ),
                const SizedBox(height: UtenSpacing.s12),
                OutlinedButton.icon(
                  key: const Key('hr-task-batch-confirm-date'),
                  icon: const Icon(Icons.event_outlined, size: 18),
                  label: Text(fmt(selected)),
                  onPressed: () async {
                    final picked = await showDatePicker(
                      context: dialogContext,
                      initialDate: selected,
                      firstDate: DateTime(2000),
                      lastDate: today,
                      locale: const Locale('zh'),
                    );
                    if (picked != null) {
                      setDialogState(() => selected = picked);
                    }
                  },
                ),
              ],
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
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    return ok == true ? fmt(selected) : null;
  }

  /// 批量送祝福：只发「今日 ∩ 本年未祝福 ∩ 已选中」，服务端按(员工,类型,当年)再去重。
  Future<void> _batchBless(Set<String> ids, List<HrTaskItem> toBless) async {
    if (_batchBusy || ids.isEmpty) return;
    final targets = toBless
        .where((item) => ids.contains(item.employeeId))
        .map((item) => item.employeeId)
        .toList();
    final skipped = ids.length - targets.length;
    if (targets.isEmpty) {
      context.appError('所选同事不在今日名单或本年已祝福，未发送');
      return;
    }
    if (targets.length > kHrTaskBatchLimit) {
      context.appError(
        '单次最多批量处理 $kHrTaskBatchLimit 人，请分批操作（当前 ${targets.length} 人）',
      );
      return;
    }
    setState(() => _batchBusy = true);
    final noticeType = _type == HrTaskType.birthday
        ? NoticeType.birthday
        : NoticeType.anniversary;
    try {
      final result = await ref
          .read(noticeRepositoryProvider)
          .publishCelebrationBatch(type: noticeType, employeeIds: targets);
      if (!mounted) return;
      // V454：一天一类型一张聚合卡；toast 说清「卡数 + 覆盖人数」
      final covered = result.notices > 0
          ? '已发布祝福卡，覆盖 ${result.published} 位同事'
          : '所选同事均已祝福';
      context.appSuccess(
        '$covered'
        '${result.skipped > 0 ? '（${result.skipped} 人本年已祝福）' : ''}'
        '${skipped > 0 ? '，$skipped 人不在今日名单已跳过' : ''}',
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appApiError(e);
    } finally {
      if (mounted) {
        setState(() {
          _batchBusy = false;
          _selectedIds = {};
        });
      }
      // 重取 summary → 同步工作台/部门徽标（已祝福者不再计入，角标即减）。
      await ref.read(hrTaskSummaryProvider.notifier).reloadSilently();
    }
  }

  // ═══════════════════════ 窄屏：卡片列表（移动端手感） ═══════════════════════

  Widget _mobileList(
    HrTaskSummary s,
    List<HrTaskItem> items,
    List<HrTaskItem> toBless,
    bool canPublish,
  ) {
    return ListView(
      key: const Key('hr-task-mobile-list'),
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        if (_type == HrTaskType.confirm)
          _hint(
            context,
            '试用期 ${s.probationMonths} 个月口径；'
            '被认领的事项显示「处理中」，他人不可重复操作。',
          ),
        if (_isCelebration && canPublish && toBless.isNotEmpty)
          _celebrationBatchBar(context, toBless),
        if (items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s24),
            child: UtenEmpty(message: _type.emptyText),
          )
        else
          Card(
            margin: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              UtenSpacing.s8,
              UtenSpacing.s12,
              0,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  HrTaskTile(
                    type: _type,
                    item: items[i],
                    isToday: hrTaskIsToday(s, _type, items[i]),
                  ),
                ],
              ],
            ),
          ),
        if (_type == HrTaskType.confirm && s.unconfirmedLegacyCount > 0)
          _hint(
            context,
            '另有 ${s.unconfirmedLegacyCount} 名入职满一年的员工未登记转正日期，'
            '请在员工档案中补录。',
          ),
      ],
    );
  }

  /// 庆典一键批量送祝福条（窄屏）：对今日未祝福者一键发布默认模板祝福。
  /// 宽屏走表格多选 +「批量送祝福(N)」，不再重复出条。
  Widget _celebrationBatchBar(BuildContext context, List<HrTaskItem> toBless) {
    final theme = Theme.of(context);
    final noun = _type == HrTaskType.birthday ? '生日' : '入职周年';
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
        0,
      ),
      child: Card(
        clipBehavior: Clip.antiAlias,
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s8,
          ),
          child: Row(
            children: [
              Icon(
                _type == HrTaskType.birthday
                    ? Icons.cake_rounded
                    : Icons.emoji_events_rounded,
                color: theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '一键为今日$noun的 ${toBless.length} 人发布一张聚合祝福卡',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              FilledButton.icon(
                onPressed: _batchBusy
                    ? null
                    : () => _batchBless({
                        for (final item in toBless) item.employeeId,
                      }, toBless),
                icon: const Icon(Icons.send_rounded, size: 18),
                label: const Text('一键全部'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hint(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s16,
        UtenSpacing.s4,
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
