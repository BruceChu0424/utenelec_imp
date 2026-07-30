// AdminAuditLogPage - 审计日志查看（超级管理员）
//
// 谁在什么时候做了什么：导出下载 / 登录 / 改密 / 数据变更（DB 触发器写入）。
// 写侧由各模块 audit.logExplicit(...) / 触发器落 audit_log 表，本页是读侧。
// 仅超级管理员（authorization:manage + 后端 superAdmin）可见。
//
// 复刻 account_page.dart 的 MasterDataTableView + 翻页 + 搜索范式，但：
//   * 无 autofilter（审计日志无需列筛选，用动作 chip 替代）
//   * 无新增/编辑/删除（只读）
//   * 动作 chip：全部 / 仅导出 / 登录 / 改密 / 数据变更（单一选择，前缀匹配后端 action）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/audit_log_entry.dart';
import '../repositories/audit_log_repository.dart';

class AdminAuditLogPage extends ConsumerStatefulWidget {
  const AdminAuditLogPage({super.key});

  @override
  ConsumerState<AdminAuditLogPage> createState() => _AdminAuditLogPageState();
}

class _AdminAuditLogPageState extends ConsumerState<AdminAuditLogPage> {
  /// 当前动作筛选（前缀匹配后端 action）：null = 全部。
  /// chip 顺序与 [_actionChips] 对齐。
  String? _actionFilter;

  /// 操作人账号搜索词（后端 LIKE）。
  String _search = '';

  PagedResult<AuditLogEntry>? _page;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();

  /// 动作 chip 定义：(label, 前缀|null)。null 表示"全部"。
  static const _actionChips = <(String, String?)>[
    ('全部', null),
    ('仅导出', 'export'),
    ('登录', 'login'),
    ('改密', 'change_password'),
    ('数据变更', 'insert'),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page) async {
    final generation = _loadRequests.begin();
    setState(() {
      _loading = true;
      _error = null;
      _pageNum = page;
    });
    try {
      final r = await ref
          .read(auditLogRepositoryProvider)
          .list(
            page: page,
            action: _actionFilter,
            actorAccount: _search.trim().isEmpty ? null : _search.trim(),
          );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _error = '加载审计日志失败';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String v) {
    final t = v.trim();
    if (t == _search) return;
    _search = t;
    _load(1);
  }

  void _onChipTap(String? prefix) {
    if (_actionFilter == prefix) return;
    _actionFilter = prefix;
    _load(1);
  }

  /// createdAt ISO → 中国标准时间 'yyyy-MM-dd HH:mm'。解析失败回退原值。
  static String _fmtTime(String? iso) {
    return ChinaDateTime.formatIsoInstant(iso, fallback: iso ?? '');
  }

  /// 动作 → 友好标签（导出动作归一为"导出 xxx 报表"）。
  static String _actionLabel(String action) {
    if (action.startsWith('export_')) {
      // export_purchase_report → 导出 · 采购报表
      final seg = action.substring('export_'.length); // purchase_report
      String cn = seg;
      const map = {
        'purchase_report': '采购报表',
        'sales_report': '销售报表',
        'subcontract_report': '委外报表',
        'production_report': '生产报表',
        'finance_report': '钱流报表',
        'warehouse_report': '仓库报表',
      };
      cn = map[seg] ?? seg;
      return '导出 · $cn';
    }
    return switch (action) {
      'login' => '登录',
      'login_failed' => '登录失败',
      'logout' => '登出',
      'change_password' => '修改密码',
      'change_password_failed' => '修改密码失败',
      'insert' => '新增',
      'update' => '修改',
      'delete' => '删除',
      'refresh_reuse' => '令牌重用',
      _ => action,
    };
  }

  static String _resultLabel(String? r) {
    if (r == null || r.isEmpty) return '';
    return switch (r) {
      'success' => '成功',
      'failure' => '失败',
      'account_not_found' => '账号不存在',
      'bad_password' => '密码错误',
      'reuse_detected' => '检测到重用',
      _ => r,
    };
  }

  static final _columns = <MasterColumnDef<AuditLogEntry>>[
    MasterColumnDef(
      key: 'createdAt',
      label: '时间',
      width: 160,
      value: (a) => _fmtTime(a.createdAt),
    ),
    MasterColumnDef(
      key: 'actorAccount',
      label: '操作人',
      width: 140,
      value: (a) => a.actorAccount ?? '(系统)',
    ),
    MasterColumnDef(
      key: 'action',
      label: '动作',
      width: 200,
      value: (a) => _actionLabel(a.action),
    ),
    MasterColumnDef(
      key: 'targetType',
      label: '对象类型',
      width: 160,
      value: (a) => a.targetType ?? '',
    ),
    MasterColumnDef(
      key: 'targetId',
      label: '对象 / 说明',
      width: 240,
      value: (a) => a.targetId ?? '',
    ),
    MasterColumnDef(
      key: 'ip',
      label: 'IP',
      width: 140,
      value: (a) => a.ip ?? '',
    ),
    MasterColumnDef(
      key: 'result',
      label: '结果',
      width: 110,
      value: (a) => _resultLabel(a.result),
    ),
  ];

  Future<void> _refresh() => _load(1);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = _page?.total ?? 0;
    return Scaffold(
      appBar: UtenAppBar(
        title: '审计日志',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Column(
              children: [
                // 标题行：图标 + 计数 + 搜索框
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: UtenSpacing.s8,
                    left: UtenSpacing.s4,
                    right: UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 18,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      Text(
                        '审计日志 ($total)',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(
                        child: UtenSearchBar(
                          hint: '搜索操作人账号',
                          initialValue: _search,
                          onChanged: _onSearchChanged,
                        ),
                      ),
                    ],
                  ),
                ),
                // 动作筛选 chip 行（单一选择）
                SizedBox(
                  height: 38,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s4,
                    ),
                    children: [
                      for (final (label, prefix) in _actionChips)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: UtenSpacing.s4,
                          ),
                          child: ChoiceChip(
                            label: Text(label),
                            selected: _actionFilter == prefix,
                            onSelected: (_) => _onChipTap(prefix),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                Expanded(
                  child: MasterDataTableView<AuditLogEntry>(
                    columns: _columns,
                    items: _page?.items ?? const [],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    onRowTap: (_) {},
                    isLoading: _loading && _page == null,
                    loadingMore: _loading && _page != null,
                    error: _error,
                    onRetry: () => _load(_pageNum),
                    emptyMessage: '暂无审计记录',
                    currentPage: _page?.page ?? 1,
                    totalPages: _page?.totalPages ?? 1,
                    onPageChange: (p) => _load(p),
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
