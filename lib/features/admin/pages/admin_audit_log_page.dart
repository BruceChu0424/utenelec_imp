// AdminAuditLogPage - 审计中心（授权核查人员）
//
// 面向管理员回答：谁、何时、做了什么、结果如何、是否有风险、具体改了什么。
// 写侧由请求覆盖、显式安全事件和数据库脱敏触发器共同落 audit_log，本页是只读调查入口。
// 仅持 audit_log:view 的核查人员可见；导出还需 audit_log:export。
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/audit/device_audit_store.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
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

  /// 通用检索：操作人、对象、对象 ID、API 路径或 Request ID。
  String _keyword = '';

  String? _targetTypeFilter;
  String? _eventSourceFilter;
  String _requestId = '';
  String? _operationKindFilter = 'write';
  String? _actorScopeFilter = 'user';
  int? _snapshotId;

  String? _riskFilter;
  String? _categoryFilter;
  String? _outcomeFilter;
  DateTimeRange? _dateRange;

  AuditLogPage? _page;
  AuditSummary? _summary;
  int _pageNum = 1;
  bool _loading = false;
  String? _error;
  final _loadRequests = LatestRequestGuard();
  final _searchController = TextEditingController();
  final _requestIdController = TextEditingController();

  /// 动作 chip 定义：(label, 前缀|null)。null 表示"全部"。
  static const _actionChips = <(String, String?)>[
    ('全部', null),
    ('登录认证', 'login'),
    ('数据导出', 'export'),
    ('密码操作', 'change_password'),
    ('请求操作', 'http_'),
  ];

  static const _operationChips = <(String, String?)>[
    ('全部操作', null),
    ('写入', 'write'),
    ('新增', 'create'),
    ('修改', 'update'),
    ('删除', 'delete'),
    ('读取', 'read'),
  ];

  static const _actorScopeChips = <(String, String?)>[
    ('用户操作', 'user'),
    ('全部记录', null),
    ('系统/迁移', 'system'),
  ];

  static const _targetTypeChips = <(String, String?)>[
    ('全部对象', null),
    ('货品', 'goods'),
    ('货品分类', 'material_categories'),
    ('客户', 'clients'),
    ('供应商', 'suppliers'),
  ];

  static const _eventSourceOptions = <(String, String?)>[
    ('全部来源', null),
    ('请求', 'request'),
    ('数据库变更', 'database'),
    ('业务事件', 'business'),
    ('安全拦截', 'security'),
  ];

  static final _requestIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  static const _categoryChips = <(String, String?)>[
    ('全部类型', null),
    ('安全事件', 'security'),
    ('权限变更', 'authorization'),
    ('登录认证', 'authentication'),
    ('数据导出', 'export'),
    ('数据变更', 'data_change'),
    ('业务操作', 'business'),
    ('系统设置', 'system'),
  ];

  @override
  void initState() {
    super.initState();
    final today = ChinaDateTime.today();
    _dateRange = DateTimeRange(
      start: today.subtract(const Duration(days: 6)),
      end: today,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  Future<void> _load(int page, {bool silent = false}) async {
    final generation = _loadRequests.begin();
    final requestedSnapshotId = _snapshotId;
    _pageNum = page;
    // silent（返回即刷新）：不翻 _loading、不重建，避免抢返回转场帧；数据到达后静默换。
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final repository = ref.read(auditLogRepositoryProvider);
      final pageResult = await repository.list(
        page: page,
        action: _actionFilter,
        keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
        targetType: _targetTypeFilter,
        eventSource: _eventSourceFilter,
        requestId: _requestId.trim().isEmpty ? null : _requestId.trim(),
        operationKind: _operationKindFilter,
        actorScope: _actorScopeFilter,
        snapshotId: requestedSnapshotId,
        riskLevel: _riskFilter,
        eventCategory: _categoryFilter,
        outcome: _outcomeFilter,
        dateFrom: _dateRange == null
            ? null
            : ChinaDateTime.formatDate(_dateRange!.start),
        dateTo: _dateRange == null
            ? null
            : ChinaDateTime.formatDate(_dateRange!.end),
      );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      final summary = await repository.summary(
        action: _actionFilter,
        keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
        targetType: _targetTypeFilter,
        eventSource: _eventSourceFilter,
        requestId: _requestId.trim().isEmpty ? null : _requestId.trim(),
        operationKind: _operationKindFilter,
        actorScope: _actorScopeFilter,
        snapshotId: pageResult.snapshotId,
        eventCategory: _categoryFilter,
        dateFrom: _dateRange == null
            ? null
            : ChinaDateTime.formatDate(_dateRange!.start),
        dateTo: _dateRange == null
            ? null
            : ChinaDateTime.formatDate(_dateRange!.end),
      );
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      setState(() {
        _page = pageResult;
        _summary = summary;
        _snapshotId = pageResult.snapshotId;
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      if (silent) return; // 静默刷新失败：保留旧数据，不弹错误（stale-while-revalidate）
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !_loadRequests.isCurrent(generation)) return;
      if (silent) return;
      setState(() {
        _error = '加载审计日志失败';
        _loading = false;
      });
    }
  }

  void _onSearchChanged(String v) {
    final t = v.trim();
    if (t == _keyword) return;
    _keyword = t;
    _reloadFromFirstPage();
  }

  void _onRequestIdDraftChanged(String v) {
    final t = v.trim();
    if (_requestId.isEmpty || t == _requestId) return;
    _requestId = '';
    _reloadFromFirstPage();
  }

  void _onRequestIdSubmitted(String v) {
    final t = v.trim();
    if (t.isEmpty) {
      if (_requestId.isEmpty) return;
      _requestId = '';
      _reloadFromFirstPage();
      return;
    }
    if (!_requestIdPattern.hasMatch(t)) {
      context.appWarning('请输入完整的 Request ID；部分内容请使用左侧通用搜索。');
      return;
    }
    if (t == _requestId) return;
    _requestId = t;
    _reloadFromFirstPage();
  }

  void _locateRequest(String requestId) {
    if (!_requestIdPattern.hasMatch(requestId)) return;
    setState(() {
      _requestId = requestId;
      _requestIdController.text = requestId;
      _keyword = '';
      _searchController.clear();
      _actionFilter = null;
      _operationKindFilter = null;
      _actorScopeFilter = null;
      _targetTypeFilter = null;
      _eventSourceFilter = null;
      _categoryFilter = null;
      _riskFilter = null;
      _outcomeFilter = null;
      _snapshotId = null;
    });
    _load(1);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _requestIdController.dispose();
    super.dispose();
  }

  void _reloadFromFirstPage() {
    setState(() => _snapshotId = null);
    _load(1);
  }

  void _onChipTap(String? prefix) {
    if (_actionFilter == prefix) return;
    setState(() {
      _actionFilter = prefix;
      if (prefix != null) {
        _operationKindFilter = null;
      }
      if (prefix == 'login') {
        _actorScopeFilter = null;
      }
      _snapshotId = null;
    });
    _load(1);
  }

  void _onOperationKindChanged(String? value) {
    if (_operationKindFilter == value) return;
    setState(() {
      _operationKindFilter = value;
      _snapshotId = null;
    });
    _load(1);
  }

  void _onActorScopeChanged(String? value) {
    if (_actorScopeFilter == value) return;
    setState(() {
      _actorScopeFilter = value;
      _snapshotId = null;
    });
    _load(1);
  }

  void _onTargetTypeChanged(String? value) {
    if (_targetTypeFilter == value) return;
    setState(() {
      _targetTypeFilter = value;
      _snapshotId = null;
    });
    _load(1);
  }

  void _onEventSourceChanged(String? value) {
    if (_eventSourceFilter == value) return;
    setState(() {
      _eventSourceFilter = value;
      if (value != null && value != 'database') {
        _operationKindFilter = null;
      }
      if (value == 'security') {
        _actorScopeFilter = null;
      }
      _snapshotId = null;
    });
    _load(1);
  }

  void _onCategoryChanged(String? value) {
    if (_categoryFilter == value) return;
    setState(() {
      _categoryFilter = value;
      if (value != null && value != 'data_change') {
        _operationKindFilter = null;
      }
      if (value == 'security' || value == 'authentication') {
        _actorScopeFilter = null;
      }
      _snapshotId = null;
    });
    _load(1);
  }

  void _applyDrillDown({
    String? risk,
    String? outcome,
    String? category,
    bool clear = false,
  }) {
    setState(() {
      if (clear) {
        _riskFilter = null;
        _outcomeFilter = null;
        _categoryFilter = null;
      } else {
        _riskFilter = risk;
        _outcomeFilter = outcome;
        _categoryFilter = category;
      }
      _snapshotId = null;
    });
    _load(1);
  }

  Future<void> _pickDateRange() async {
    final today = ChinaDateTime.today();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime.utc(2020),
      lastDate: today,
      initialDateRange: _dateRange,
      helpText: '选择审计时间范围',
      saveText: '应用',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _dateRange = picked;
      _snapshotId = null;
    });
    _load(1);
  }

  void _resetFilters({bool showAll = false}) {
    final today = ChinaDateTime.today();
    setState(() {
      _actionFilter = null;
      _keyword = '';
      _searchController.clear();
      _targetTypeFilter = null;
      _eventSourceFilter = null;
      _requestId = '';
      _requestIdController.clear();
      _operationKindFilter = showAll ? null : 'write';
      _actorScopeFilter = showAll ? null : 'user';
      _categoryFilter = null;
      _riskFilter = null;
      _outcomeFilter = null;
      _dateRange = DateTimeRange(
        start: today.subtract(const Duration(days: 6)),
        end: today,
      );
      _snapshotId = null;
    });
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

  Future<void> _refresh() async {
    setState(() => _snapshotId = null);
    await _load(1);
  }

  Map<String, dynamic> get _exportQueryParams => <String, dynamic>{
    if (_actionFilter != null) 'action': _actionFilter,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    if (_targetTypeFilter != null) 'targetType': _targetTypeFilter,
    if (_eventSourceFilter != null) 'eventSource': _eventSourceFilter,
    if (_requestId.trim().isNotEmpty) 'requestId': _requestId.trim(),
    if (_operationKindFilter != null) 'operationKind': _operationKindFilter,
    if (_actorScopeFilter != null) 'actorScope': _actorScopeFilter,
    if (_snapshotId != null) 'snapshotId': _snapshotId,
    if (_riskFilter != null) 'riskLevel': _riskFilter,
    if (_categoryFilter != null) 'eventCategory': _categoryFilter,
    if (_outcomeFilter != null) 'outcome': _outcomeFilter,
    if (_dateRange != null)
      'dateFrom': ChinaDateTime.formatDate(_dateRange!.start),
    if (_dateRange != null) 'dateTo': ChinaDateTime.formatDate(_dateRange!.end),
  };

  String get _exportFilename {
    final range = _dateRange;
    if (range == null) return '审计日志_全部日期';
    return '审计日志_${ChinaDateTime.formatDate(range.start)}_'
        '${ChinaDateTime.formatDate(range.end)}';
  }

  Future<void> _openDetail(AuditLogEntry entry) async {
    final future = ref.read(auditLogRepositoryProvider).detail(entry.id);
    final width = MediaQuery.sizeOf(context).width;
    if (width < 720) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => FractionallySizedBox(
          heightFactor: 0.92,
          child: _AuditDetailPanel(
            future: future,
            onClose: () => Navigator.pop(sheetContext),
            onLocateRequest: (requestId) {
              Navigator.pop(sheetContext);
              _locateRequest(requestId);
            },
          ),
        ),
      );
      return;
    }
    final panelWidth = (width * 0.68).clamp(680.0, 920.0).toDouble();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭审计详情',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 280),
      pageBuilder: (dialogContext, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          elevation: 18,
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: _AuditDetailPanel(
              future: future,
              onClose: () => Navigator.pop(dialogContext),
              onLocateRequest: (requestId) {
                Navigator.pop(dialogContext);
                _locateRequest(requestId);
              },
            ),
          ),
        ),
      ),
      transitionBuilder: (_, animation, _, child) => SlideTransition(
        position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
            .animate(
              CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
            ),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 返回即刷新：从其它页面回到审计中心时重拉当前页（保留筛选/页码），
    // 保证看到最新审计记录。本页路由为静态路径，直接用 RouteName 常量。
    ref.onPageResume(
      RouteName.adminAuditLogs,
      () => _load(_pageNum, silent: true),
    );
    final items = _page?.items ?? const <AuditLogEntry>[];
    final hasDrillDown =
        _riskFilter != null ||
        _outcomeFilter != null ||
        _categoryFilter != null;
    return Scaffold(
      appBar: UtenAppBar(
        title: '审计中心',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.dashboard),
        ),
        actions: [
          UtenExportButton(
            endpoint: '${ApiEndpoints.adminAuditLogs}/export',
            report: 'filtered',
            queryParams: _exportQueryParams,
            filename: _exportFilename,
            requiredPermission: Perm.auditLogExport,
            enabled: _snapshotId != null,
            label: '导出当前结果',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: RefreshIndicator(
            onRefresh: _refresh,
            child: CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.only(top: UtenSpacing.s8),
                    child: _AuditHero(),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s16),
                    child: _AuditMetricGrid(
                      summary: _summary,
                      selectedRisk: _riskFilter,
                      selectedOutcome: _outcomeFilter,
                      selectedCategory: _categoryFilter,
                      onAll: () => _applyDrillDown(clear: true),
                      onRisk: () => _applyDrillDown(risk: 'risky'),
                      onCritical: () => _applyDrillDown(risk: 'critical'),
                      onFailure: () => _applyDrillDown(outcome: 'failure'),
                      onDataChange: () =>
                          _applyDrillDown(category: 'data_change'),
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s16),
                    child: _AuditFilterPanel(
                      searchController: _searchController,
                      requestIdController: _requestIdController,
                      actionFilter: _actionFilter,
                      operationKindFilter: _operationKindFilter,
                      actorScopeFilter: _actorScopeFilter,
                      targetTypeFilter: _targetTypeFilter,
                      eventSourceFilter: _eventSourceFilter,
                      categoryFilter: _categoryFilter,
                      riskFilter: _riskFilter,
                      outcomeFilter: _outcomeFilter,
                      dateRange: _dateRange,
                      actionChips: _actionChips,
                      operationChips: _operationChips,
                      actorScopeChips: _actorScopeChips,
                      targetTypeChips: _targetTypeChips,
                      eventSourceOptions: _eventSourceOptions,
                      categoryChips: _categoryChips,
                      onSearchChanged: _onSearchChanged,
                      onRequestIdChanged: _onRequestIdDraftChanged,
                      onRequestIdSubmitted: _onRequestIdSubmitted,
                      onActionChanged: _onChipTap,
                      onOperationKindChanged: _onOperationKindChanged,
                      onActorScopeChanged: _onActorScopeChanged,
                      onTargetTypeChanged: _onTargetTypeChanged,
                      onEventSourceChanged: _onEventSourceChanged,
                      onCategoryChanged: _onCategoryChanged,
                      onRiskChanged: (value) {
                        setState(() {
                          _riskFilter = value;
                          _snapshotId = null;
                        });
                        _load(1);
                      },
                      onOutcomeChanged: (value) {
                        setState(() {
                          _outcomeFilter = value;
                          _snapshotId = null;
                        });
                        _load(1);
                      },
                      onPickDate: _pickDateRange,
                      onClear: _resetFilters,
                    ),
                  ),
                ),
                if (_summary != null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.only(top: UtenSpacing.s16),
                      child: _AuditTrendCard(points: _summary!.dailyTrend),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.only(
                      top: UtenSpacing.s24,
                      bottom: UtenSpacing.s8,
                    ),
                    child: _AuditListHeader(
                      total: _page?.total ?? 0,
                      hasDrillDown: hasDrillDown,
                      onClearDrillDown: () => _applyDrillDown(clear: true),
                    ),
                  ),
                ),
                if (_loading)
                  const SliverToBoxAdapter(child: LinearProgressIndicator()),
                if (_error != null)
                  SliverToBoxAdapter(
                    child: _AuditErrorCard(
                      message: _error!,
                      onRetry: () => _load(_pageNum),
                    ),
                  )
                else if (!_loading && items.isEmpty)
                  SliverToBoxAdapter(
                    child: _AuditEmptyCard(
                      onShowAll: () => _resetFilters(showAll: true),
                    ),
                  )
                else
                  SliverList.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: UtenSpacing.s8),
                    itemBuilder: (context, index) => _AuditEventTile(
                      entry: items[index],
                      onTap: () => _openDetail(items[index]),
                    ),
                  ),
                if (_page != null && _error == null)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s20,
                      ),
                      child: _AuditPagination(
                        currentPage: _page!.page,
                        totalPages: _page!.totalPages,
                        loading: _loading,
                        onPageChanged: _load,
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(
                  child: SizedBox(height: UtenSpacing.s32),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AuditHero extends StatelessWidget {
  const _AuditHero();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      elevation: UtenCardElevation.low,
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '谁，在什么时候，做了什么',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '按用户、动作、对象、结果和风险原因查看每一次操作；点击任意记录可追溯请求与脱敏数据变更。',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s16),
              const Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  UtenStatusBadge(
                    label: '写操作全量留痕',
                    type: UtenStatusBadgeType.success,
                    icon: Icons.fact_check_outlined,
                  ),
                  UtenStatusBadge(
                    label: '风险规则可解释',
                    type: UtenStatusBadgeType.warning,
                    icon: Icons.policy_outlined,
                  ),
                  UtenStatusBadge(
                    label: '详情自动脱敏',
                    type: UtenStatusBadgeType.info,
                    icon: Icons.visibility_off_outlined,
                  ),
                ],
              ),
            ],
          );
          final icon = Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: UtenRadius.xlAll,
            ),
            child: Icon(
              Icons.shield_outlined,
              size: 36,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          );
          if (constraints.maxWidth < 640) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                icon,
                const SizedBox(height: UtenSpacing.s16),
                copy,
              ],
            );
          }
          return Row(
            children: [
              icon,
              const SizedBox(width: UtenSpacing.s20),
              Expanded(child: copy),
            ],
          );
        },
      ),
    );
  }
}

class _AuditMetricGrid extends StatelessWidget {
  const _AuditMetricGrid({
    required this.summary,
    required this.selectedRisk,
    required this.selectedOutcome,
    required this.selectedCategory,
    required this.onAll,
    required this.onRisk,
    required this.onCritical,
    required this.onFailure,
    required this.onDataChange,
  });

  final AuditSummary? summary;
  final String? selectedRisk;
  final String? selectedOutcome;
  final String? selectedCategory;
  final VoidCallback onAll;
  final VoidCallback onRisk;
  final VoidCallback onCritical;
  final VoidCallback onFailure;
  final VoidCallback onDataChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cards = [
      _MetricSpec(
        '全部操作',
        summary?.total,
        Icons.receipt_long_outlined,
        theme.colorScheme.primary,
        selectedRisk == null &&
            selectedOutcome == null &&
            selectedCategory == null,
        onAll,
      ),
      _MetricSpec(
        '风险行为',
        summary?.riskCount,
        Icons.warning_amber_rounded,
        theme.colorScheme.tertiary,
        selectedRisk == 'risky',
        onRisk,
      ),
      _MetricSpec(
        '严重风险',
        summary?.criticalCount,
        Icons.gpp_bad_outlined,
        theme.colorScheme.error,
        selectedRisk == 'critical',
        onCritical,
      ),
      _MetricSpec(
        '失败操作',
        summary?.failedCount,
        Icons.error_outline_rounded,
        theme.colorScheme.error,
        selectedOutcome == 'failure',
        onFailure,
      ),
      _MetricSpec(
        '数据变更',
        summary?.dataChangeCount,
        Icons.data_object_rounded,
        theme.colorScheme.secondary,
        selectedCategory == 'data_change',
        onDataChange,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1100
            ? 5
            : constraints.maxWidth >= 720
            ? 3
            : constraints.maxWidth >= 360
            ? 2
            : 1;
        const gap = UtenSpacing.s8;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final card in cards)
              SizedBox(
                width: width,
                child: _AuditMetricCard(spec: card),
              ),
          ],
        );
      },
    );
  }
}

class _AuditMetricCard extends StatelessWidget {
  const _AuditMetricCard({required this.spec});

  final _MetricSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: spec.selected,
      label: '${spec.label} ${spec.value ?? '加载中'}，点击筛选具体记录',
      child: UtenCard(
        onTap: spec.onTap,
        child: SizedBox(
          height: 82,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: spec.color.withValues(alpha: 0.12),
                      borderRadius: UtenRadius.mdAll,
                    ),
                    child: Icon(spec.icon, size: 19, color: spec.color),
                  ),
                  const Spacer(),
                  if (spec.selected)
                    Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: spec.color,
                    ),
                ],
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Text(
                      spec.label,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    spec.value?.toString() ?? '—',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: spec.selected ? spec.color : null,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricSpec {
  const _MetricSpec(
    this.label,
    this.value,
    this.icon,
    this.color,
    this.selected,
    this.onTap,
  );

  final String label;
  final int? value;
  final IconData icon;
  final Color color;
  final bool selected;
  final VoidCallback onTap;
}

class _AuditFilterPanel extends StatelessWidget {
  const _AuditFilterPanel({
    required this.searchController,
    required this.requestIdController,
    required this.actionFilter,
    required this.operationKindFilter,
    required this.actorScopeFilter,
    required this.targetTypeFilter,
    required this.eventSourceFilter,
    required this.categoryFilter,
    required this.riskFilter,
    required this.outcomeFilter,
    required this.dateRange,
    required this.actionChips,
    required this.operationChips,
    required this.actorScopeChips,
    required this.targetTypeChips,
    required this.eventSourceOptions,
    required this.categoryChips,
    required this.onSearchChanged,
    required this.onRequestIdChanged,
    required this.onRequestIdSubmitted,
    required this.onActionChanged,
    required this.onOperationKindChanged,
    required this.onActorScopeChanged,
    required this.onTargetTypeChanged,
    required this.onEventSourceChanged,
    required this.onCategoryChanged,
    required this.onRiskChanged,
    required this.onOutcomeChanged,
    required this.onPickDate,
    required this.onClear,
  });

  final TextEditingController searchController;
  final TextEditingController requestIdController;
  final String? actionFilter;
  final String? operationKindFilter;
  final String? actorScopeFilter;
  final String? targetTypeFilter;
  final String? eventSourceFilter;
  final String? categoryFilter;
  final String? riskFilter;
  final String? outcomeFilter;
  final DateTimeRange? dateRange;
  final List<(String, String?)> actionChips;
  final List<(String, String?)> operationChips;
  final List<(String, String?)> actorScopeChips;
  final List<(String, String?)> targetTypeChips;
  final List<(String, String?)> eventSourceOptions;
  final List<(String, String?)> categoryChips;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String> onRequestIdChanged;
  final ValueChanged<String> onRequestIdSubmitted;
  final ValueChanged<String?> onActionChanged;
  final ValueChanged<String?> onOperationKindChanged;
  final ValueChanged<String?> onActorScopeChanged;
  final ValueChanged<String?> onTargetTypeChanged;
  final ValueChanged<String?> onEventSourceChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String?> onRiskChanged;
  final ValueChanged<String?> onOutcomeChanged;
  final VoidCallback onPickDate;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dateLabel = dateRange == null
        ? '全部时间'
        : '${ChinaDateTime.formatDate(dateRange!.start)} 至 '
              '${ChinaDateTime.formatDate(dateRange!.end)}';
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.filter_alt_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '筛选与检索',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: const Text('重置'),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          LayoutBuilder(
            builder: (context, constraints) {
              final searchField = Semantics(
                key: const ValueKey('audit-keyword-field'),
                textField: true,
                label: '审计通用搜索',
                child: UtenSearchBar(
                  hint: '搜索操作人、对象、对象 ID 或 API',
                  controller: searchController,
                  onChanged: onSearchChanged,
                ),
              );
              final requestField = Semantics(
                key: const ValueKey('audit-request-id-field'),
                textField: true,
                label: '按 Request ID 定位',
                child: UtenSearchBar(
                  hint: '精确定位 Request ID',
                  controller: requestIdController,
                  onChanged: onRequestIdChanged,
                  onSubmitted: onRequestIdSubmitted,
                ),
              );
              final dateButton = OutlinedButton.icon(
                onPressed: onPickDate,
                icon: const Icon(Icons.date_range_outlined),
                label: Text(dateLabel),
              );
              if (constraints.maxWidth < 680) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    searchField,
                    const SizedBox(height: UtenSpacing.s8),
                    requestField,
                    const SizedBox(height: UtenSpacing.s8),
                    dateButton,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(flex: 2, child: searchField),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(child: requestField),
                  const SizedBox(width: UtenSpacing.s12),
                  dateButton,
                ],
              );
            },
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '可搜索操作人、对象、对象 ID、API 或 Request ID；货品名称不在搜索范围。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _AuditFilterChoiceGroup(
            title: '操作类型',
            semanticPrefix: '操作类型',
            keyPrefix: 'audit-operation',
            value: operationKindFilter,
            options: operationChips,
            onChanged: onOperationKindChanged,
          ),
          const SizedBox(height: UtenSpacing.s16),
          _AuditFilterChoiceGroup(
            title: '记录范围',
            semanticPrefix: '记录范围',
            keyPrefix: 'audit-scope',
            value: actorScopeFilter,
            options: actorScopeChips,
            onChanged: onActorScopeChanged,
          ),
          const SizedBox(height: UtenSpacing.s16),
          _AuditFilterChoiceGroup(
            title: '业务对象',
            semanticPrefix: '业务对象',
            keyPrefix: 'audit-target',
            value: targetTypeFilter,
            options: targetTypeChips,
            onChanged: onTargetTypeChanged,
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '查货品或分类记录时，先选业务对象，再选新增、修改或删除。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _AuditFilterChoiceGroup(
            title: '事件类型',
            semanticPrefix: '事件类型',
            keyPrefix: 'audit-category',
            value: categoryFilter,
            options: categoryChips,
            onChanged: onCategoryChanged,
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _AuditFilterMenu(
                label: '事件来源',
                value: eventSourceFilter,
                options: eventSourceOptions,
                onChanged: onEventSourceChanged,
              ),
              _AuditFilterMenu(
                label: '原始动作',
                value: actionFilter,
                options: actionChips,
                onChanged: onActionChanged,
              ),
              _AuditFilterMenu(
                label: '风险等级',
                value: riskFilter,
                options: const [
                  ('全部风险', null),
                  ('有风险', 'risky'),
                  ('严重', 'critical'),
                  ('高风险', 'high'),
                  ('需关注', 'medium'),
                  ('低风险', 'low'),
                ],
                onChanged: onRiskChanged,
              ),
              _AuditFilterMenu(
                label: '操作结果',
                value: outcomeFilter,
                options: const [
                  ('全部结果', null),
                  ('成功', 'success'),
                  ('失败', 'failure'),
                ],
                onChanged: onOutcomeChanged,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AuditFilterChoiceGroup extends StatelessWidget {
  const _AuditFilterChoiceGroup({
    required this.title,
    required this.semanticPrefix,
    required this.keyPrefix,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String title;
  final String semanticPrefix;
  final String keyPrefix;
  final String? value;
  final List<(String, String?)> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final (label, optionValue) in options)
              Semantics(
                button: true,
                selected: value == optionValue,
                label: '$semanticPrefix：$label',
                child: ChoiceChip(
                  key: ValueKey('$keyPrefix-${optionValue ?? 'all'}'),
                  label: Text(label),
                  selected: value == optionValue,
                  onSelected: (_) => onChanged(optionValue),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _AuditFilterMenu extends StatelessWidget {
  const _AuditFilterMenu({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String? value;
  final List<(String, String?)> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.firstWhere(
      (item) => item.$2 == value,
      orElse: () => options.first,
    );
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: (selectedValue) =>
          onChanged(selectedValue.isEmpty ? null : selectedValue),
      itemBuilder: (context) => [
        for (final option in options)
          PopupMenuItem<String>(
            value: option.$2 ?? '',
            child: Row(
              children: [
                Icon(
                  option.$2 == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(option.$1),
              ],
            ),
          ),
      ],
      child: Chip(
        avatar: const Icon(Icons.tune_rounded, size: 18),
        label: Text('$label：${selected.$1}'),
      ),
    );
  }
}

class _AuditTrendCard extends StatelessWidget {
  const _AuditTrendCard({required this.points});

  final List<AuditDailyPoint> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxValue = points.fold<int>(
      1,
      (value, point) => math.max(value, point.total),
    );
    final total = points.fold<int>(0, (value, point) => value + point.total);
    final risks = points.fold<int>(
      0,
      (value, point) => value + point.riskCount,
    );
    return Semantics(
      label: '近七天操作趋势，共 $total 次操作，其中 $risks 次风险行为',
      child: UtenCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart_rounded, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '近 7 天操作趋势',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const UtenStatusBadge(
                  label: '红色为风险行为',
                  type: UtenStatusBadgeType.danger,
                  size: UtenStatusBadgeSize.small,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s16),
            SizedBox(
              height: 126,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final point in points)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              '${point.total}',
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor: math.max(
                                    point.total / maxValue,
                                    0.04,
                                  ),
                                  child: ClipRRect(
                                    borderRadius: UtenRadius.smAll,
                                    child: Column(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        if (point.total - point.riskCount > 0)
                                          Expanded(
                                            flex: point.total - point.riskCount,
                                            child: ColoredBox(
                                              color: theme
                                                  .colorScheme
                                                  .primaryContainer,
                                            ),
                                          ),
                                        if (point.riskCount > 0)
                                          Expanded(
                                            flex: point.riskCount,
                                            child: ColoredBox(
                                              color: theme.colorScheme.error,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              point.date.length >= 10
                                  ? point.date.substring(5)
                                  : point.date,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AuditListHeader extends StatelessWidget {
  const _AuditListHeader({
    required this.total,
    required this.hasDrillDown,
    required this.onClearDrillDown,
  });

  final int total;
  final bool hasDrillDown;
  final VoidCallback onClearDrillDown;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '操作记录 · $total 条',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        if (hasDrillDown)
          TextButton.icon(
            onPressed: onClearDrillDown,
            icon: const Icon(Icons.close_rounded, size: 18),
            label: const Text('清除卡片筛选'),
          ),
      ],
    );
  }
}

class _AuditEventTile extends StatelessWidget {
  const _AuditEventTile({required this.entry, required this.onTap});

  final AuditLogEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = entry.summary?.trim().isNotEmpty == true
        ? entry.summary!
        : '${_AdminAuditLogPageState._actionLabel(entry.action)} · '
              '${entry.targetType ?? '系统'}';
    final actor = entry.actorAccount?.trim().isNotEmpty == true
        ? entry.actorAccount!
        : entry.actorId?.trim().isNotEmpty == true
        ? '用户 ${entry.actorId!.substring(0, math.min(8, entry.actorId!.length))}'
        : '系统任务';
    final detailBits = <String>[
      if (entry.targetId?.trim().isNotEmpty == true) '对象 ${entry.targetId}',
      if (entry.deviceLabel?.trim().isNotEmpty == true &&
          entry.deviceLabel != '未提供设备信息')
        '设备 ${entry.deviceLabel}',
      if (entry.ip?.trim().isNotEmpty == true) 'IP ${entry.ip}',
      if (entry.statusCode != null) 'HTTP ${entry.statusCode}',
    ];
    return Semantics(
      button: true,
      label: '$actor，$summary，${_riskLabel(entry.riskLevel)}，点击查看详情',
      child: UtenCard(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final icon = _AuditRiskIcon(level: entry.riskLevel);
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 17,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Flexible(
                      child: Text(
                        actor,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  summary,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (detailBits.isNotEmpty) ...[
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    detailBits.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            );
            final trailing = Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _AuditRiskBadge(level: entry.riskLevel),
                const SizedBox(height: UtenSpacing.s8),
                _AuditResultBadge(
                  result: entry.result,
                  statusCode: entry.statusCode,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  _AdminAuditLogPageState._fmtTime(entry.createdAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            );
            if (constraints.maxWidth < 660) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      icon,
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(child: content),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Row(
                    children: [
                      _AuditRiskBadge(level: entry.riskLevel),
                      const SizedBox(width: UtenSpacing.s8),
                      _AuditResultBadge(
                        result: entry.result,
                        statusCode: entry.statusCode,
                      ),
                      const Spacer(),
                      Text(
                        _AdminAuditLogPageState._fmtTime(entry.createdAt),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(width: UtenSpacing.s4),
                      const Icon(Icons.chevron_right_rounded),
                    ],
                  ),
                ],
              );
            }
            return Row(
              children: [
                icon,
                const SizedBox(width: UtenSpacing.s16),
                Expanded(child: content),
                const SizedBox(width: UtenSpacing.s16),
                trailing,
                const SizedBox(width: UtenSpacing.s8),
                const Icon(Icons.chevron_right_rounded),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _AuditRiskIcon extends StatelessWidget {
  const _AuditRiskIcon({required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    final color = _riskColor(context, level);
    final icon = switch (level) {
      'critical' => Icons.gpp_bad_outlined,
      'high' => Icons.warning_amber_rounded,
      'medium' => Icons.info_outline_rounded,
      _ => Icons.check_circle_outline_rounded,
    };
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Icon(icon, color: color),
    );
  }
}

class _AuditRiskBadge extends StatelessWidget {
  const _AuditRiskBadge({required this.level});

  final String level;

  @override
  Widget build(BuildContext context) {
    final type = switch (level) {
      'critical' => UtenStatusBadgeType.danger,
      'high' => UtenStatusBadgeType.danger,
      'medium' => UtenStatusBadgeType.warning,
      _ => UtenStatusBadgeType.success,
    };
    return UtenStatusBadge(
      label: _riskLabel(level),
      type: type,
      icon: level == 'low' ? Icons.check_rounded : Icons.warning_amber_rounded,
      size: UtenStatusBadgeSize.small,
    );
  }
}

class _AuditResultBadge extends StatelessWidget {
  const _AuditResultBadge({required this.result, required this.statusCode});

  final String? result;
  final int? statusCode;

  @override
  Widget build(BuildContext context) {
    final failed =
        (statusCode != null && statusCode! >= 400) ||
        (result != null && result != 'success' && result != '');
    return UtenStatusBadge(
      label: failed ? '失败' : '成功',
      type: failed ? UtenStatusBadgeType.danger : UtenStatusBadgeType.success,
      size: UtenStatusBadgeSize.small,
    );
  }
}

String _riskLabel(String level) => switch (level) {
  'critical' => '严重风险',
  'high' => '高风险',
  'medium' => '需关注',
  _ => '低风险',
};

Color _riskColor(BuildContext context, String level) {
  final colors = Theme.of(context).colorScheme;
  return switch (level) {
    'critical' || 'high' => colors.error,
    'medium' => colors.tertiary,
    _ => colors.primary,
  };
}

class _AuditErrorCard extends StatelessWidget {
  const _AuditErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        children: [
          Icon(
            Icons.error_outline_rounded,
            color: Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(child: Text(message)),
          TextButton(onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

class _AuditEmptyCard extends StatelessWidget {
  const _AuditEmptyCard({required this.onShowAll});

  final VoidCallback onShowAll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s40),
      child: Column(
        children: [
          Icon(
            Icons.manage_search_rounded,
            size: 44,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text('没有符合条件的操作记录', style: theme.textTheme.titleMedium),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '可清除操作类型、记录范围或业务对象；如需更早记录，请调整日期。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          OutlinedButton.icon(
            onPressed: onShowAll,
            icon: const Icon(Icons.filter_alt_off_outlined),
            label: const Text('清除业务筛选（保留最近 7 天）'),
          ),
        ],
      ),
    );
  }
}

class _AuditPagination extends StatefulWidget {
  const _AuditPagination({
    required this.currentPage,
    required this.totalPages,
    required this.loading,
    required this.onPageChanged,
  });

  final int currentPage;
  final int totalPages;
  final bool loading;
  final ValueChanged<int> onPageChanged;

  @override
  State<_AuditPagination> createState() => _AuditPaginationState();
}

class _AuditPaginationState extends State<_AuditPagination> {
  late final TextEditingController _controller;

  int get _lastPage => math.max(widget.totalPages, 1);

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: '${widget.currentPage}');
  }

  @override
  void didUpdateWidget(covariant _AuditPagination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPage != widget.currentPage &&
        _controller.text != '${widget.currentPage}') {
      _controller.text = '${widget.currentPage}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _jump() {
    final parsed = int.tryParse(_controller.text.trim());
    if (parsed == null) {
      _controller.text = '${widget.currentPage}';
      return;
    }
    final page = parsed.clamp(1, _lastPage).toInt();
    _controller.text = '$page';
    if (!widget.loading && page != widget.currentPage) {
      widget.onPageChanged(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: [
        IconButton(
          tooltip: '上一页',
          onPressed: !widget.loading && widget.currentPage > 1
              ? () => widget.onPageChanged(widget.currentPage - 1)
              : null,
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Text('第 ${widget.currentPage} / $_lastPage 页'),
        SizedBox(
          width: 88,
          child: Semantics(
            textField: true,
            label: '跳转页码，范围 1 到 $_lastPage',
            child: TextField(
              key: const ValueKey('audit-page-jump-field'),
              controller: _controller,
              enabled: !widget.loading,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _jump(),
              decoration: const InputDecoration(labelText: '页码', isDense: true),
            ),
          ),
        ),
        FilledButton.tonal(
          key: const ValueKey('audit-page-jump-button'),
          onPressed: widget.loading ? null : _jump,
          child: const Text('跳转'),
        ),
        IconButton(
          tooltip: '下一页',
          onPressed: !widget.loading && widget.currentPage < widget.totalPages
              ? () => widget.onPageChanged(widget.currentPage + 1)
              : null,
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ],
    );
  }
}

class _AuditDetailPanel extends StatelessWidget {
  const _AuditDetailPanel({
    required this.future,
    required this.onClose,
    required this.onLocateRequest,
  });

  final Future<AuditLogDetail> future;
  final VoidCallback onClose;
  final ValueChanged<String> onLocateRequest;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AuditLogDetail>(
      future: future,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(
            child: CircularProgressIndicator(strokeWidth: 2.5),
          );
        }
        if (snapshot.hasError || snapshot.data == null) {
          final message = snapshot.error is ApiException
              ? (snapshot.error! as ApiException).message
              : '审计详情加载失败';
          return Column(
            children: [
              _AuditDetailHeader(title: '审计详情', onClose: onClose),
              Expanded(
                child: Center(
                  child: Text(
                    message,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              ),
            ],
          );
        }
        return _AuditDetailContent(
          detail: snapshot.data!,
          onClose: onClose,
          onLocateRequest: onLocateRequest,
        );
      },
    );
  }
}

class _AuditDetailContent extends StatelessWidget {
  const _AuditDetailContent({
    required this.detail,
    required this.onClose,
    required this.onLocateRequest,
  });

  final AuditLogDetail detail;
  final VoidCallback onClose;
  final ValueChanged<String> onLocateRequest;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AuditDetailHeader(
                title: '审计详情 #${detail.id}',
                subtitle:
                    detail.summary ??
                    _AdminAuditLogPageState._actionLabel(detail.action),
                onLocateRequest: detail.requestId?.trim().isNotEmpty == true
                    ? () => onLocateRequest(detail.requestId!)
                    : null,
                onClose: onClose,
              ),
              const TabBar(
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [
                  Tab(icon: Icon(Icons.subject_outlined), text: '概览'),
                  Tab(icon: Icon(Icons.compare_arrows_rounded), text: '数据变更'),
                  Tab(icon: Icon(Icons.devices_other_rounded), text: '设备证据'),
                  Tab(icon: Icon(Icons.code_rounded), text: '技术信息'),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Expanded(
                child: TabBarView(
                  children: [
                    _AuditOverviewTab(detail: detail),
                    _AuditChangeTab(detail: detail),
                    _AuditDeviceTab(detail: detail),
                    _AuditTechnicalTab(detail: detail),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AuditOverviewTab extends StatelessWidget {
  const _AuditOverviewTab({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        Container(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          decoration: BoxDecoration(
            color: _riskColor(
              context,
              detail.riskLevel,
            ).withValues(alpha: 0.10),
            borderRadius: UtenRadius.lgAll,
            border: Border.all(
              color: _riskColor(
                context,
                detail.riskLevel,
              ).withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _AuditRiskIcon(level: detail.riskLevel),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _AuditRiskBadge(level: detail.riskLevel),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      detail.riskReason ?? '未提供风险说明',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '风险等级由固定规则计算，用于排查优先级，不代表已经发生安全事故。',
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
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          child: Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(label: '谁做的', value: detail.actorAccount ?? '系统任务'),
              _AuditFact(
                label: '几点做的',
                value: _AdminAuditLogPageState._fmtTime(detail.createdAt),
              ),
              _AuditFact(
                label: '做了什么',
                value:
                    detail.actionLabel ??
                    _AdminAuditLogPageState._actionLabel(detail.action),
              ),
              _AuditFact(
                label: '操作对象',
                value: detail.objectLabel ?? detail.targetType ?? '系统',
              ),
              _AuditFact(label: '对象标识', value: detail.targetId ?? '—'),
              _AuditFact(
                label: '结果',
                value: _AdminAuditLogPageState._resultLabel(detail.result),
              ),
              _AuditFact(label: '来源 IP', value: detail.ip ?? '—'),
              _AuditFact(
                label: '事件类型',
                value: _categoryLabel(detail.eventCategory),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AuditChangeTab extends StatelessWidget {
  const _AuditChangeTab({required this.detail});

  final AuditLogDetail detail;

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final before = _decode(detail.beforeJson);
    final after = _decode(detail.afterJson);
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    final changed = keys
        .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
        .toList(growable: false);
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                changed.isEmpty ? '没有字段级快照' : '共 ${changed.length} 个字段发生变化',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const UtenStatusBadge(
              label: '敏感字段已剔除',
              type: UtenStatusBadgeType.info,
              size: UtenStatusBadgeSize.small,
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (changed.isEmpty)
          UtenCard(
            child: Text(
              '这条记录可能是请求级事件，或相关表没有字段快照。可在技术信息中查看请求路径与状态码。',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          )
        else
          UtenCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < changed.length; index++) ...[
                  _AuditDiffRow(
                    field: changed[index],
                    before: before[changed[index]],
                    after: after[changed[index]],
                  ),
                  if (index != changed.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        const SizedBox(height: UtenSpacing.s12),
        _AuditJsonExpansion(label: '查看变更前原始 JSON', rawJson: detail.beforeJson),
        const SizedBox(height: UtenSpacing.s8),
        _AuditJsonExpansion(label: '查看变更后原始 JSON', rawJson: detail.afterJson),
      ],
    );
  }
}

class _AuditDiffRow extends StatelessWidget {
  const _AuditDiffRow({required this.field, this.before, this.after});

  final String field;
  final dynamic before;
  final dynamic after;

  String _value(dynamic value) {
    if (value == null) return '—';
    if (value is Map || value is List) {
      return const JsonEncoder.withIndent('  ').convert(value);
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            field,
            style: theme.textTheme.labelLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          LayoutBuilder(
            builder: (context, constraints) {
              final oldValue = _AuditDiffValue(
                label: '变更前',
                value: _value(before),
              );
              final newValue = _AuditDiffValue(
                label: '变更后',
                value: _value(after),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    oldValue,
                    const SizedBox(height: UtenSpacing.s8),
                    newValue,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: oldValue),
                  const Padding(
                    padding: EdgeInsets.all(UtenSpacing.s8),
                    child: Icon(Icons.arrow_forward_rounded),
                  ),
                  Expanded(child: newValue),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _AuditDiffValue extends StatelessWidget {
  const _AuditDiffValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          SelectableText(value, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _AuditJsonExpansion extends StatelessWidget {
  const _AuditJsonExpansion({required this.label, required this.rawJson});

  final String label;
  final String? rawJson;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        title: Text(label),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                _AuditJsonPanel._pretty(rawJson),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _LocalReceiptAuthorizationState { idle, loading, authorized, failed }

class _AuditDeviceTab extends ConsumerStatefulWidget {
  const _AuditDeviceTab({required this.detail});

  final AuditLogDetail detail;

  @override
  ConsumerState<_AuditDeviceTab> createState() => _AuditDeviceTabState();
}

class _AuditDeviceTabState extends ConsumerState<_AuditDeviceTab> {
  _LocalReceiptAuthorizationState _authorization =
      _LocalReceiptAuthorizationState.idle;

  String? get _eventId =>
      widget.detail.clientEventId ?? widget.detail.device?.clientEventId;

  Future<void> _authorizeLocalReceiptRead() async {
    final eventId = _eventId;
    if (eventId == null ||
        eventId.trim().isEmpty ||
        _authorization == _LocalReceiptAuthorizationState.loading) {
      return;
    }
    setState(() => _authorization = _LocalReceiptAuthorizationState.loading);
    try {
      await ref
          .read(apiClientProvider)
          .post(ApiEndpoints.adminAuditLocalReceiptVerification(eventId));
      if (!mounted) return;
      setState(
        () => _authorization = _LocalReceiptAuthorizationState.authorized,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _authorization = _LocalReceiptAuthorizationState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_authorization == _LocalReceiptAuthorizationState.authorized) {
      return _AuthorizedAuditDeviceTab(detail: widget.detail);
    }

    final eventId = _eventId;
    final assessment = _preAuthorizationDeviceAssessment(
      detail: widget.detail,
      eventId: eventId,
      state: _authorization,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _DeviceEvidenceBanner(assessment: assessment),
        const SizedBox(height: UtenSpacing.s12),
        _ServerDeviceCard(detail: widget.detail),
        const SizedBox(height: UtenSpacing.s12),
        _CorrelationCard(detail: widget.detail, receipt: null),
        const SizedBox(height: UtenSpacing.s12),
        _LocalReceiptAuthorizationCard(
          eventId: eventId,
          state: _authorization,
          onAuthorize: _authorizeLocalReceiptRead,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _DeviceTrustNotice(captureStatus: widget.detail.device?.captureStatus),
      ],
    );
  }
}

_DeviceEvidenceAssessment _preAuthorizationDeviceAssessment({
  required AuditLogDetail detail,
  required String? eventId,
  required _LocalReceiptAuthorizationState state,
}) {
  final server = detail.device;
  if (server == null ||
      server.captureStatus == 'legacy' ||
      server.captureStatus == 'missing') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '这条记录没有设备快照',
      '可能是功能升级前的历史记录，或请求并非来自新版 Uten 客户端。服务器操作记录仍然有效。',
    );
  }
  if (server.captureStatus == 'invalid') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '客户端设备信息无效',
      '服务器拒绝了格式异常的设备上下文，但仍保留请求、账号、IP、结果与时间用于调查。',
    );
  }
  if (eventId == null || eventId.trim().isEmpty) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '没有可核查的本地操作 ID',
      '本条服务器记录缺少本地操作 ID，因此不会读取当前设备的本机信息或回执。',
    );
  }
  return switch (state) {
    _LocalReceiptAuthorizationState.loading => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.loading,
      '正在申请本机回执核查授权',
      '服务端正在校验当前人员的审计查看权限并记录本次核查；此时尚未读取本机数据。',
    ),
    _LocalReceiptAuthorizationState.failed => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '本机回执核查未获授权',
      '需联网完成授权核查；未读取本机安装标识、设备信息或操作回执。',
    ),
    _ => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '尚未核查本机回执',
      '当前只展示服务器保存的证据。点击“授权并核对本机回执”后，服务端将校验权限并记录本次核查。',
    ),
  };
}

class _LocalReceiptAuthorizationCard extends StatelessWidget {
  const _LocalReceiptAuthorizationCard({
    required this.eventId,
    required this.state,
    required this.onAuthorize,
  });

  final String? eventId;
  final _LocalReceiptAuthorizationState state;
  final VoidCallback onAuthorize;

  @override
  Widget build(BuildContext context) {
    final loading = state == _LocalReceiptAuthorizationState.loading;
    final failed = state == _LocalReceiptAuthorizationState.failed;
    final canAuthorize = eventId?.trim().isNotEmpty == true && !loading;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.admin_panel_settings_outlined,
            title: '授权读取当前设备的本机回执',
            subtitle: '仅按这条记录的完整本地操作 ID 精确核查，不支持枚举；授权请求本身也会写入审计日志。',
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            eventId == null || eventId!.trim().isEmpty
                ? '本条记录没有本地操作 ID，无法发起核查。'
                : failed
                ? '需联网完成授权核查；未读取本机回执。请确认权限和网络后重试。'
                : '授权成功前，页面不会读取本机安装标识、设备资料或操作回执。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: UtenSpacing.s12),
          FilledButton.icon(
            key: const ValueKey('authorize-local-audit-receipt'),
            onPressed: canAuthorize ? onAuthorize : null,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    failed
                        ? Icons.refresh_rounded
                        : Icons.phonelink_lock_outlined,
                  ),
            label: Text(
              loading
                  ? '正在授权…'
                  : failed
                  ? '重新授权并核对'
                  : '授权并核对本机回执',
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorizedAuditDeviceTab extends ConsumerWidget {
  const _AuthorizedAuditDeviceTab({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = detail.device;
    final eventId = detail.clientEventId ?? device?.clientEventId;
    final currentAsync = ref.watch(currentDeviceAuditProfileProvider);
    final receiptAsync = eventId == null
        ? null
        : ref.watch(localAuditReceiptProvider(eventId));
    final current = currentAsync.valueOrNull;
    final receipt = receiptAsync?.valueOrNull;
    final assessment = _assessDeviceEvidence(
      detail: detail,
      current: current,
      receipt: receipt,
      profileLoading: currentAsync.isLoading,
      profileFailed: currentAsync.hasError,
      receiptLoading: receiptAsync?.isLoading ?? false,
      receiptFailed: receiptAsync?.hasError ?? false,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _DeviceEvidenceBanner(assessment: assessment),
        const SizedBox(height: UtenSpacing.s12),
        _ServerDeviceCard(detail: detail),
        const SizedBox(height: UtenSpacing.s12),
        _CorrelationCard(detail: detail, receipt: receipt),
        if (receipt != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _LocalReceiptCard(detail: detail, receipt: receipt),
        ] else if (current != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _CurrentDeviceCard(profile: current),
        ],
        const SizedBox(height: UtenSpacing.s12),
        _DeviceTrustNotice(captureStatus: device?.captureStatus),
      ],
    );
  }
}

enum _DeviceEvidenceState {
  matched,
  partial,
  mismatch,
  otherDevice,
  localMissing,
  invalid,
  unavailable,
  loading,
}

class _DeviceEvidenceAssessment {
  const _DeviceEvidenceAssessment(this.state, this.title, this.description);

  final _DeviceEvidenceState state;
  final String title;
  final String description;
}

_DeviceEvidenceAssessment _assessDeviceEvidence({
  required AuditLogDetail detail,
  required DeviceAuditProfile? current,
  required LocalAuditReceipt? receipt,
  required bool profileLoading,
  required bool profileFailed,
  required bool receiptLoading,
  required bool receiptFailed,
}) {
  final server = detail.device;
  if (server == null ||
      server.captureStatus == 'legacy' ||
      server.captureStatus == 'missing') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '这条记录没有设备快照',
      '可能是功能升级前的历史记录，或请求并非来自新版 Uten 客户端。服务器操作记录仍然有效。',
    );
  }
  if (server.captureStatus == 'invalid') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '客户端设备信息无效',
      '服务器拒绝了格式异常的设备上下文，但仍保留请求、账号、IP、结果与时间用于调查。',
    );
  }
  if (profileLoading || receiptLoading) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.loading,
      '正在核对本机回执',
      '正在读取当前设备的安全存储，不影响服务器审计记录。',
    );
  }
  if (profileFailed || current == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '当前设备信息不可读取',
      '设备插件或本机安全存储不可用，暂时只能查看服务器记录。',
    );
  }
  if (server.installationId == null ||
      server.installationId != current.installationId) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.otherDevice,
      '当前查看设备不是原操作设备',
      '浏览器和应用不能远程读取另一台设备的本地安全存储；请在原设备按本地操作 ID 核查回执。',
    );
  }
  if (receiptFailed || receipt == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.localMissing,
      '服务器有记录，本机回执未找到',
      '本机最多保留最近 300 条，并按系统审计总留存月数清理；清理站点数据、卸载应用或本机存储异常也会使回执不可用。',
    );
  }
  if (!receipt.integrityVerified) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '本机回执完整性校验失败',
      '本机数据可能被修改、密钥已变化或写入中断；不能把这份回执作为一致性依据。服务器记录不受影响。',
    );
  }
  final attempt = receipt.attemptForRequest(detail.requestId);
  if (attempt == null) {
    if (receipt.allAttempts.every((value) => value.serverRequestId == null)) {
      return const _DeviceEvidenceAssessment(
        _DeviceEvidenceState.partial,
        '本机回执缺少服务器 Request ID',
        '旧响应或中间网络设备没有回显关联编号；设备与本地操作仍可人工查看，但不能自动锁定具体请求尝试。',
      );
    }
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.mismatch,
      '未找到这一次服务器请求的本机尝试',
      '同一个本地操作可能因刷新令牌或网络重试产生多次 Request ID；本机尝试链中没有当前这一条。',
    );
  }
  if (attempt.outcome == 'pending' || attempt.completedAt == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '本机回执仍未完成',
      '应用可能在响应落盘前退出，或本机写入仍在进行；请稍后重开详情核查。',
    );
  }
  if (!_receiptMatches(detail, receipt)) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.mismatch,
      '本机回执与服务器记录不一致',
      '至少一个关联编号、请求字段或设备快照不同，请结合 IP、时间和字段变更人工复核。',
    );
  }
  if (attempt.serverRequestId == null || detail.requestId == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '设备与操作信息一致，关联证据不完整',
      '本机设备快照和请求字段一致，但旧响应没有完整回显服务器 Request ID。',
    );
  }
  return const _DeviceEvidenceAssessment(
    _DeviceEvidenceState.matched,
    '本机回执与服务器记录一致',
    '安装标识、设备快照、操作 ID、服务器 Request ID 与可比请求字段一致。此结论表示记录一致，不是硬件身份认证。',
  );
}

bool _receiptMatches(AuditLogDetail detail, LocalAuditReceipt receipt) {
  final server = detail.device;
  final attempt = receipt.attemptForRequest(detail.requestId);
  if (!receipt.integrityVerified ||
      attempt == null ||
      server == null ||
      server.installationId != receipt.installationId) {
    return false;
  }
  final eventId = detail.clientEventId ?? server.clientEventId;
  if (eventId == null || eventId != receipt.clientEventId) return false;
  if (detail.httpMethod != null &&
      detail.httpMethod!.toUpperCase() != attempt.method.toUpperCase()) {
    return false;
  }
  if (detail.httpPath != null && detail.httpPath != attempt.path) return false;
  if (detail.statusCode != null &&
      attempt.statusCode != null &&
      detail.statusCode != attempt.statusCode) {
    return false;
  }
  if (detail.statusCode != null) {
    final expectedOutcome = detail.statusCode! >= 400 ? 'failure' : 'success';
    if (attempt.outcome != expectedOutcome) return false;
  }
  if (!_sameInstant(server.clientEventAt, attempt.startedAt)) return false;
  return _sameValue(server.deviceName, receipt.device.deviceName) &&
      _sameValue(server.manufacturer, receipt.device.manufacturer) &&
      _sameValue(server.model, receipt.device.model) &&
      _sameValue(server.platform, receipt.device.platform) &&
      _sameValue(server.osVersion, receipt.device.osVersion) &&
      _sameValue(server.appVersion, receipt.device.appVersion) &&
      _sameValue(server.appBuild, receipt.device.appBuild) &&
      _sameValue(server.formFactor, receipt.device.formFactor) &&
      _sameValue(server.browserName, receipt.device.browserName) &&
      _sameValue(server.locale, receipt.device.locale) &&
      _sameValue(server.timeZone, receipt.device.timeZone) &&
      server.timeZoneOffsetMinutes == receipt.device.timeZoneOffsetMinutes &&
      server.physicalDevice == receipt.device.isPhysicalDevice;
}

bool _sameValue(String? left, String? right) =>
    (left ?? '').trim() == (right ?? '').trim();

bool _sameInstant(String? left, String? right) {
  if (left == null || right == null) return left == right;
  final leftTime = DateTime.tryParse(left)?.toUtc();
  final rightTime = DateTime.tryParse(right)?.toUtc();
  return leftTime != null && rightTime != null && leftTime == rightTime;
}

class _DeviceEvidenceBanner extends StatelessWidget {
  const _DeviceEvidenceBanner({required this.assessment});

  final _DeviceEvidenceAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (color, icon, badgeType) = switch (assessment.state) {
      _DeviceEvidenceState.matched => (
        colors.primary,
        Icons.verified_user_outlined,
        UtenStatusBadgeType.success,
      ),
      _DeviceEvidenceState.partial => (
        colors.tertiary,
        Icons.fact_check_outlined,
        UtenStatusBadgeType.warning,
      ),
      _DeviceEvidenceState.mismatch || _DeviceEvidenceState.invalid => (
        colors.error,
        Icons.gpp_bad_outlined,
        UtenStatusBadgeType.danger,
      ),
      _DeviceEvidenceState.loading => (
        colors.primary,
        Icons.sync_rounded,
        UtenStatusBadgeType.info,
      ),
      _ => (
        colors.onSurfaceVariant,
        Icons.devices_other_outlined,
        UtenStatusBadgeType.info,
      ),
    };
    return Semantics(
      liveRegion: true,
      label: '${assessment.title}。${assessment.description}',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenStatusBadge(
                    label: assessment.title,
                    type: badgeType,
                    size: UtenStatusBadgeSize.small,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    assessment.description,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerDeviceCard extends StatelessWidget {
  const _ServerDeviceCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final device = detail.device;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.dns_outlined,
            title: '服务器保存的设备快照',
            subtitle: '收到请求时清洗并固化，后续设备改名或升级不会改写历史。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          if (device == null)
            const Text('未提供')
          else
            Wrap(
              spacing: UtenSpacing.s24,
              runSpacing: UtenSpacing.s16,
              children: [
                _AuditFact(label: '设备名称', value: device.deviceName ?? '—'),
                _AuditFact(label: '设备厂商', value: device.manufacturer ?? '—'),
                _AuditFact(label: '设备型号', value: device.model ?? '—'),
                _AuditFact(label: '平台', value: device.platform ?? '—'),
                _AuditFact(label: '系统版本', value: device.osVersion ?? '—'),
                _AuditFact(
                  label: '应用版本 / 构建',
                  value:
                      '${device.appVersion ?? '—'} / ${device.appBuild ?? '—'}',
                ),
                _AuditFact(label: '设备形态', value: device.formFactor ?? '—'),
                _AuditFact(label: '浏览器', value: device.browserName ?? '—'),
                _AuditFact(label: '语言区域', value: device.locale ?? '—'),
                _AuditFact(
                  label: '本机时区',
                  value: _timeZoneLabel(
                    device.timeZone,
                    device.timeZoneOffsetMinutes,
                  ),
                ),
                _AuditFact(
                  label: '物理设备状态',
                  value: switch (device.physicalDevice) {
                    true => '客户端报告为真机',
                    false => '客户端报告为模拟器',
                    null => '未提供 / 平台不支持',
                  },
                ),
                _CopyableAuditFact(
                  label: '本机安装标识',
                  value: device.installationId ?? '—',
                ),
                _CopyableAuditFact(
                  label: '设备快照摘要',
                  value: device.profileHash ?? '—',
                ),
                _AuditFact(
                  label: '采集状态',
                  value: _captureStatusLabel(device.captureStatus),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CorrelationCard extends StatelessWidget {
  const _CorrelationCard({required this.detail, required this.receipt});

  final AuditLogDetail detail;
  final LocalAuditReceipt? receipt;

  @override
  Widget build(BuildContext context) {
    final eventId = detail.clientEventId ?? detail.device?.clientEventId;
    final localReceipt = receipt;
    final matchedAttempt = localReceipt?.attemptForRequest(detail.requestId);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.link_rounded,
            title: '操作关联编号与时间',
            subtitle: '本地操作 ID 串联客户端回执；Request ID 串联服务器请求与数据库变更。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _CopyableAuditFact(
                label: '服务器 Request ID',
                value: detail.requestId ?? '—',
              ),
              _CopyableAuditFact(label: '本地操作 ID', value: eventId ?? '—'),
              _AuditFact(
                label: '服务器记录时间',
                value: _AdminAuditLogPageState._fmtTime(detail.createdAt),
              ),
              _AuditFact(
                label: '客户端发起时间',
                value: _AdminAuditLogPageState._fmtTime(
                  detail.device?.clientEventAt,
                ),
              ),
              if (matchedAttempt != null)
                _AuditFact(
                  label: '本机回执完成时间',
                  value: _AdminAuditLogPageState._fmtTime(
                    matchedAttempt.completedAt,
                  ),
                ),
              if (localReceipt != null)
                _AuditFact(
                  label: '本机请求尝试次数',
                  value: '${localReceipt.allAttempts.length} 次',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocalReceiptCard extends StatelessWidget {
  const _LocalReceiptCard({required this.detail, required this.receipt});

  final AuditLogDetail detail;
  final LocalAuditReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final server = detail.device;
    final attempt =
        receipt.attemptForRequest(detail.requestId) ?? receipt.latestAttempt;
    final comparisons = <(String, String?, String?)>[
      ('本机安装标识', server?.installationId, receipt.installationId),
      ('设备名称', server?.deviceName, receipt.device.deviceName),
      ('设备厂商', server?.manufacturer, receipt.device.manufacturer),
      ('设备型号', server?.model, receipt.device.model),
      ('平台', server?.platform, receipt.device.platform),
      ('系统版本', server?.osVersion, receipt.device.osVersion),
      ('应用版本', server?.appVersion, receipt.device.appVersion),
      ('应用构建', server?.appBuild, receipt.device.appBuild),
      ('设备形态', server?.formFactor, receipt.device.formFactor),
      ('浏览器', server?.browserName, receipt.device.browserName),
      ('语言区域', server?.locale, receipt.device.locale),
      ('时区', server?.timeZone, receipt.device.timeZone),
      (
        '时区偏移（分钟）',
        server?.timeZoneOffsetMinutes?.toString(),
        receipt.device.timeZoneOffsetMinutes?.toString(),
      ),
      (
        '物理设备状态',
        _physicalDeviceLabel(server?.physicalDevice),
        _physicalDeviceLabel(receipt.device.isPhysicalDevice),
      ),
      (
        '客户端发起时间',
        _normalizedTime(server?.clientEventAt),
        _normalizedTime(attempt.startedAt),
      ),
      ('服务器 Request ID', detail.requestId, attempt.serverRequestId),
      ('HTTP 方法', detail.httpMethod, attempt.method),
      ('请求路径', detail.httpPath, attempt.path),
      (
        'HTTP 状态码',
        detail.statusCode?.toString(),
        attempt.statusCode?.toString(),
      ),
      (
        '请求结果',
        detail.statusCode == null
            ? null
            : detail.statusCode! >= 400
            ? 'failure'
            : 'success',
        attempt.outcome,
      ),
    ];
    return UtenCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s16),
            child: _EvidenceSectionTitle(
              icon: Icons.phonelink_lock_outlined,
              title: '当前设备的本机回执',
              subtitle: '异步尽力写入，使用安全存储中的随机密钥校验普通本地篡改；不保存请求体、查询参数或令牌。',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              0,
              UtenSpacing.s16,
              UtenSpacing.s12,
            ),
            child: UtenStatusBadge(
              label: receipt.integrityVerified ? '本机完整性校验通过' : '本机完整性校验失败',
              type: receipt.integrityVerified
                  ? UtenStatusBadgeType.success
                  : UtenStatusBadgeType.danger,
              icon: receipt.integrityVerified
                  ? Icons.verified_outlined
                  : Icons.warning_amber_rounded,
              size: UtenStatusBadgeSize.small,
            ),
          ),
          const Divider(height: 1),
          for (var index = 0; index < comparisons.length; index++) ...[
            _DeviceCompareRow(
              label: comparisons[index].$1,
              serverValue: comparisons[index].$2,
              localValue: comparisons[index].$3,
            ),
            if (index != comparisons.length - 1) const Divider(height: 1),
          ],
          const Divider(height: 1),
          ExpansionTile(
            title: Text('请求尝试链（${receipt.allAttempts.length} 次）'),
            subtitle: const Text('自动刷新令牌或网络重试会保留为同一操作下的多次请求'),
            children: [
              for (final entry in receipt.allAttempts.indexed)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text('${entry.$1 + 1}'),
                  ),
                  title: Text('${entry.$2.method} ${entry.$2.path}'),
                  subtitle: SelectableText(
                    'Request ID：${entry.$2.serverRequestId ?? '—'}\n'
                    '开始：${_AdminAuditLogPageState._fmtTime(entry.$2.startedAt)} · '
                    '完成：${_AdminAuditLogPageState._fmtTime(entry.$2.completedAt)}',
                  ),
                  trailing: Text(
                    '${entry.$2.statusCode ?? '—'} · ${entry.$2.outcome}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String? _physicalDeviceLabel(bool? value) => switch (value) {
  true => 'physical',
  false => 'emulator',
  null => null,
};

String? _normalizedTime(String? value) =>
    value == null ? null : DateTime.tryParse(value)?.toUtc().toIso8601String();

class _CurrentDeviceCard extends StatelessWidget {
  const _CurrentDeviceCard({required this.profile});

  final DeviceAuditProfile profile;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.computer_rounded,
            title: '当前查看设备',
            subtitle: '仅用于判断能否读取原操作设备的本地回执。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(label: '设备', value: profile.displayLabel),
              _AuditFact(label: '平台', value: profile.platform),
              _CopyableAuditFact(
                label: '本机安装标识',
                value: profile.installationId,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceCompareRow extends StatelessWidget {
  const _DeviceCompareRow({
    required this.label,
    required this.serverValue,
    required this.localValue,
  });

  final String label;
  final String? serverValue;
  final String? localValue;

  @override
  Widget build(BuildContext context) {
    final comparable =
        serverValue?.trim().isNotEmpty == true &&
        localValue?.trim().isNotEmpty == true;
    final matches = comparable && _sameValue(serverValue, localValue);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final status = UtenStatusBadge(
            label: !comparable
                ? '不可比'
                : matches
                ? '一致'
                : '不一致',
            type: !comparable
                ? UtenStatusBadgeType.info
                : matches
                ? UtenStatusBadgeType.success
                : UtenStatusBadgeType.danger,
            icon: !comparable
                ? Icons.remove_rounded
                : matches
                ? Icons.check_rounded
                : Icons.close_rounded,
            size: UtenStatusBadgeSize.small,
          );
          final serverPanel = _AuditDiffValue(
            label: '服务器',
            value: serverValue?.trim().isNotEmpty == true ? serverValue! : '—',
          );
          final localPanel = _AuditDiffValue(
            label: '本机回执',
            value: localValue?.trim().isNotEmpty == true ? localValue! : '—',
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  status,
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (constraints.maxWidth < 520)
                Column(
                  children: [
                    serverPanel,
                    const SizedBox(height: UtenSpacing.s8),
                    localPanel,
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: serverPanel),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(child: localPanel),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EvidenceSectionTitle extends StatelessWidget {
  const _EvidenceSectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeviceTrustNotice extends StatelessWidget {
  const _DeviceTrustNotice({required this.captureStatus});

  final String? captureStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '可信度说明：服务器可以证明它在该时间收到这些客户端声明并处理了请求；本机 HMAC 只能发现普通编辑或写入损坏，回执仍可被清除，改造客户端也能伪造设备名、型号和安装标识。系统不采集 IMEI、MAC、硬盘序列号。若需更强证明，应另接企业 MDM、设备证书或平台设备证明。当前采集状态：${_captureStatusLabel(captureStatus)}。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableAuditFact extends StatelessWidget {
  const _CopyableAuditFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Row(
            children: [
              Expanded(child: SelectableText(value)),
              IconButton(
                tooltip: '复制$label',
                onPressed: value == '—'
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (context.mounted) context.appSuccess('$label已复制');
                      },
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _timeZoneLabel(String? name, int? offsetMinutes) {
  if (name == null && offsetMinutes == null) return '—';
  if (offsetMinutes == null) return name ?? '—';
  final sign = offsetMinutes >= 0 ? '+' : '-';
  final absolute = offsetMinutes.abs();
  final hours = (absolute ~/ 60).toString().padLeft(2, '0');
  final minutes = (absolute % 60).toString().padLeft(2, '0');
  return '${name ?? '本机时区'} · UTC$sign$hours:$minutes';
}

String _captureStatusLabel(String? value) => switch (value) {
  'present' => '完整',
  'partial' => '部分字段',
  'invalid' => '格式无效',
  'missing' => '未提供',
  'legacy' => '历史记录',
  _ => '未知',
};

class _AuditTechnicalTab extends StatelessWidget {
  const _AuditTechnicalTab({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        UtenCard(
          child: Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(label: '原始动作', value: detail.action),
              _AuditFact(label: '原始对象类型', value: detail.targetType ?? '—'),
              _AuditFact(
                label: '事件来源',
                value: _sourceLabel(detail.eventSource),
              ),
              _AuditFact(label: '请求关联 ID', value: detail.requestId ?? '—'),
              _AuditFact(label: 'HTTP 方法', value: detail.httpMethod ?? '—'),
              _AuditFact(
                label: 'HTTP 状态码',
                value: detail.statusCode?.toString() ?? '—',
              ),
              _AuditFact(
                label: '处理耗时',
                value: detail.durationMs == null
                    ? '—'
                    : '${detail.durationMs} ms',
              ),
            ],
          ),
        ),
        if (detail.httpPath?.trim().isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s12),
          UtenCard(
            child: _AuditFact(label: '请求路径', value: detail.httpPath!),
          ),
        ],
        if (detail.userAgent?.trim().isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s12),
          UtenCard(
            child: _AuditFact(
              label: '客户端 User-Agent',
              value: detail.userAgent!,
            ),
          ),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '请求正文、密码、令牌、手机号、地址、银行账号和自由文本不会复制进审计详情。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

String _categoryLabel(String value) => switch (value) {
  'security' => '安全事件',
  'authorization' => '权限变更',
  'authentication' => '登录认证',
  'export' => '数据导出',
  'data_change' => '数据变更',
  'system' => '系统设置',
  _ => '业务操作',
};

String _sourceLabel(String value) => switch (value) {
  'request' => '请求覆盖记录',
  'database' => '数据库变更快照',
  'security' => '安全层拒绝事件',
  _ => '业务显式事件',
};

class _AuditDetailHeader extends StatelessWidget {
  const _AuditDetailHeader({
    required this.title,
    required this.onClose,
    this.subtitle,
    this.onLocateRequest,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final VoidCallback? onLocateRequest;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (onLocateRequest != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('audit-locate-same-request'),
                onPressed: onLocateRequest,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('查看同一操作'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuditFact extends StatelessWidget {
  const _AuditFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SelectableText(value),
        ],
      ),
    );
  }
}

class _AuditJsonPanel extends StatelessWidget {
  const _AuditJsonPanel({
    required this.label,
    required this.rawJson,
    required this.icon,
  });

  final String label;
  final String? rawJson;
  final IconData icon;

  static String _pretty(String? value) {
    if (value == null || value.trim().isEmpty) return '无';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } catch (_) {
      return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: SelectableText(
                _pretty(rawJson),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
