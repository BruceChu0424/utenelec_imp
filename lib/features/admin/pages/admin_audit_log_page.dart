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
import 'package:go_router/go_router.dart';

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
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/repositories/public_settings_repository.dart';
import '../models/audit_event_presentation.dart';
import '../models/audit_field_labels.dart';
import '../models/audit_log_entry.dart';
import '../models/audit_session.dart';
import '../repositories/audit_log_repository.dart';
import '../widgets/audit_query_scope.dart';
import '../widgets/audit_session_card.dart';

part 'audit_overview_widgets.dart';
part 'audit_detail_panel.dart';
part 'audit_device_evidence.dart';

class AdminAuditLogPage extends ConsumerStatefulWidget {
  const AdminAuditLogPage({this.initialRequestId, super.key});

  final String? initialRequestId;

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
  String? _operationKindFilter;
  String? _actorScopeFilter = 'user';
  int? _snapshotId;

  AuditActorOption? _selectedActor;
  bool _anonymousMode = false;
  bool _systemAnomalyMode = false;
  bool _scopeApplied = false;
  String? _riskFilter;
  String? _categoryFilter;
  String? _outcomeFilter;
  DateTimeRange? _dateRange;

  AuditLogPage? _page;
  AuditSummary? _summary;
  bool _summaryFailed = false;
  AuditSessionPage? _sessionPage;
  int _pageNum = 1;
  int _sessionPageNum = 1;
  bool _loading = false;
  bool _sessionLoading = false;
  bool _preferSessionView = true;
  String? _error;
  String? _sessionError;
  final _loadRequests = LatestRequestGuard();
  final _sessionLoadRequests = LatestRequestGuard();
  final _searchController = TextEditingController();
  final _requestIdController = TextEditingController();
  final _scrollController = ScrollController();

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
    ('业务操作', 'business'),
    ('系统设置', 'system'),
  ];

  @override
  void initState() {
    super.initState();
    _scheduleInitialRequestInvestigation();
  }

  @override
  void didUpdateWidget(covariant AdminAuditLogPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialRequestId != widget.initialRequestId) {
      _scheduleInitialRequestInvestigation();
    }
  }

  void _scheduleInitialRequestInvestigation() {
    final requestId = widget.initialRequestId?.trim();
    if (requestId == null || !_requestIdPattern.hasMatch(requestId)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _requestId == requestId) return;
      _locateRequest(requestId);
    });
  }

  Future<void> _load(int page, {bool silent = false}) async {
    if (!_canLoad) return;
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
        actorId: _requestId.isEmpty && !_anonymousMode && !_systemAnomalyMode
            ? _selectedActor?.actorId
            : null,
        keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
        targetType: _targetTypeFilter,
        eventSource: _eventSourceFilter,
        requestId: _requestId.trim().isEmpty ? null : _requestId.trim(),
        operationKind: _operationKindFilter,
        actorScope: _actorScopeFilter,
        activityOnly: !_isRequestInvestigation,
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
      // List visibility must not wait for the optional aggregate query.
      // Both reads still use the same server-issued high-water mark.
      setState(() {
        _page = pageResult;
        _snapshotId = pageResult.snapshotId;
        _loading = false;
        _error = null;
        _summaryFailed = false;
        if (requestedSnapshotId == null) _summary = null;
      });
      if (requestedSnapshotId == null || _summary == null) {
        try {
          final summary = await repository.summary(
            action: _actionFilter,
            actorId:
                _requestId.isEmpty && !_anonymousMode && !_systemAnomalyMode
                ? _selectedActor?.actorId
                : null,
            keyword: _keyword.trim().isEmpty ? null : _keyword.trim(),
            targetType: _targetTypeFilter,
            eventSource: _eventSourceFilter,
            requestId: _requestId.trim().isEmpty ? null : _requestId.trim(),
            operationKind: _operationKindFilter,
            actorScope: _actorScopeFilter,
            activityOnly: !_isRequestInvestigation,
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
          setState(() => _summary = summary);
        } catch (_) {
          if (!mounted || !_loadRequests.isCurrent(generation)) return;
          setState(() => _summaryFailed = true);
        }
      }
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

  Future<void> _loadSessions(int page, {bool silent = false}) async {
    final actor = _selectedActor;
    final range = _dateRange;
    if (!_canUseSessionView || actor == null || range == null) return;
    final generation = _sessionLoadRequests.begin();
    final requestedSnapshotId = _snapshotId;
    _sessionPageNum = page;
    if (!silent) {
      setState(() {
        _sessionLoading = true;
        _sessionError = null;
      });
    }
    try {
      final pageResult = await ref
          .read(auditLogRepositoryProvider)
          .sessions(
            actorId: actor.actorId,
            dateFrom: ChinaDateTime.formatDate(range.start),
            dateTo: ChinaDateTime.formatDate(range.end),
            page: page,
            snapshotAuditId: requestedSnapshotId,
          );
      if (!mounted || !_sessionLoadRequests.isCurrent(generation)) return;
      setState(() {
        _sessionPage = pageResult;
        _snapshotId = pageResult.snapshotAuditId;
        _sessionLoading = false;
        _sessionError = null;
      });
    } on ApiException catch (error) {
      if (!mounted || !_sessionLoadRequests.isCurrent(generation)) return;
      if (silent) return;
      setState(() {
        _sessionError = error.message;
        _sessionLoading = false;
      });
    } catch (_) {
      if (!mounted || !_sessionLoadRequests.isCurrent(generation)) return;
      if (silent) return;
      setState(() {
        _sessionError = '加载登录会话失败';
        _sessionLoading = false;
      });
    }
  }

  bool get _isRequestInvestigation =>
      _requestIdPattern.hasMatch(_requestId.trim());

  bool get _canUseSessionView =>
      _scopeApplied &&
      _selectedActor != null &&
      !_anonymousMode &&
      !_systemAnomalyMode &&
      !_isRequestInvestigation &&
      _dateRange != null;

  bool get _sessionMode => _canUseSessionView && _preferSessionView;

  bool get _activeLoading => _sessionMode ? _sessionLoading : _loading;

  bool get _canLoad =>
      _isRequestInvestigation ||
      (_scopeApplied &&
          (_selectedActor != null || _anonymousMode || _systemAnomalyMode) &&
          _dateRange != null);

  String get _dateRangeLabel {
    final range = _dateRange;
    if (range == null) return '尚未选择日期';
    final start = ChinaDateTime.formatDate(range.start);
    final end = ChinaDateTime.formatDate(range.end);
    return start == end ? '$start(单日)' : '$start 至 $end';
  }

  void _invalidateScopeResults() {
    _loadRequests.begin();
    _sessionLoadRequests.begin();
    _scopeApplied = false;
    _snapshotId = null;
    _page = null;
    _summary = null;
    _sessionPage = null;
    _error = null;
    _sessionError = null;
    _loading = false;
    _sessionLoading = false;
    _pageNum = 1;
    _sessionPageNum = 1;
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
    _locateRequest(t);
  }

  void _locateRequest(String requestId) {
    if (!_requestIdPattern.hasMatch(requestId)) return;
    setState(() {
      _selectedActor = null;
      _anonymousMode = false;
      _systemAnomalyMode = false;
      _dateRange = null;
      _scopeApplied = false;
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
      _sessionPage = null;
      _sessionError = null;
      _sessionLoading = false;
      _preferSessionView = false;
    });
    _load(1);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _requestIdController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _reloadFromFirstPage() {
    setState(() => _snapshotId = null);
    if (!_canLoad) return;
    if (_sessionMode) {
      _loadSessions(1);
    } else {
      _load(1);
    }
  }

  void _onChipTap(String? prefix) {
    if (_actionFilter == prefix) return;
    setState(() {
      _actionFilter = prefix;
      if (prefix != null) {
        _operationKindFilter = null;
      }
      if (!_anonymousMode && !_systemAnomalyMode && prefix == 'login') {
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
      if (!_anonymousMode && !_systemAnomalyMode && value == 'security') {
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
      if (!_anonymousMode &&
          !_systemAnomalyMode &&
          (value == 'security' || value == 'authentication')) {
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
    if (_selectedActor == null && !_anonymousMode && !_systemAnomalyMode) {
      context.appWarning('请先选择要查看的人员。');
      return;
    }
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
    if (picked.duration.inDays > 30) {
      context.appWarning('一次最多查看连续 31 天，请缩短日期区间。');
      return;
    }
    setState(() {
      _dateRange = picked;
      _invalidateScopeResults();
    });
  }

  void _setDatePreset(int dayCount) {
    if (_selectedActor == null && !_anonymousMode && !_systemAnomalyMode) {
      context.appWarning('请先选择要查看的人员。');
      return;
    }
    final today = ChinaDateTime.today();
    setState(() {
      _dateRange = DateTimeRange(
        start: today.subtract(Duration(days: dayCount - 1)),
        end: today,
      );
      _invalidateScopeResults();
    });
  }

  Future<void> _pickActor() async {
    final width = MediaQuery.sizeOf(context).width;
    final AuditActorOption? picked;
    if (width < 720) {
      picked = await showModalBottomSheet<AuditActorOption>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const FractionallySizedBox(
          heightFactor: 0.9,
          child: AuditActorPicker(),
        ),
      );
    } else {
      picked = await showDialog<AuditActorOption>(
        context: context,
        builder: (_) => const Dialog(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(width: 640, height: 640, child: AuditActorPicker()),
        ),
      );
    }
    if (picked == null || !mounted) return;
    setState(() {
      _selectedActor = picked;
      _anonymousMode = false;
      _systemAnomalyMode = false;
      _requestId = '';
      _requestIdController.clear();
      _actorScopeFilter = 'user';
      _preferSessionView = true;
      _invalidateScopeResults();
    });
  }

  void _applyScopeQuery() {
    if (_selectedActor == null && !_anonymousMode && !_systemAnomalyMode) {
      context.appWarning('请先选择要查看的人员。');
      return;
    }
    if (_dateRange == null) {
      context.appWarning('请选择单日或最长 31 天的日期区间。');
      return;
    }
    setState(() {
      _scopeApplied = true;
      _requestId = '';
      _requestIdController.clear();
      _actorScopeFilter = _systemAnomalyMode
          ? 'system'
          : _anonymousMode
          ? 'anonymous'
          : 'user';
      _snapshotId = null;
      _page = null;
      _summary = null;
      _sessionPage = null;
      _error = null;
      _sessionError = null;
      _preferSessionView = _selectedActor != null;
    });
    if (_sessionMode) {
      _loadSessions(1);
    } else {
      _load(1);
    }
  }

  void _clearScope() {
    _loadRequests.begin();
    _sessionLoadRequests.begin();
    setState(() {
      _selectedActor = null;
      _anonymousMode = false;
      _systemAnomalyMode = false;
      _dateRange = null;
      _scopeApplied = false;
      _requestId = '';
      _requestIdController.clear();
      _snapshotId = null;
      _page = null;
      _summary = null;
      _sessionPage = null;
      _error = null;
      _sessionError = null;
      _loading = false;
      _sessionLoading = false;
      _preferSessionView = true;
    });
  }

  void _selectAnonymousScope() {
    setState(() {
      _selectedActor = null;
      _anonymousMode = true;
      _systemAnomalyMode = false;
      _actorScopeFilter = 'anonymous';
      _preferSessionView = false;
      _requestId = '';
      _requestIdController.clear();
      _invalidateScopeResults();
    });
  }

  void _selectSystemAnomalyScope() {
    setState(() {
      _selectedActor = null;
      _anonymousMode = false;
      _systemAnomalyMode = true;
      _actorScopeFilter = 'system';
      _preferSessionView = false;
      _requestId = '';
      _requestIdController.clear();
      _invalidateScopeResults();
    });
  }

  void _resetFilters() {
    setState(() {
      _actionFilter = null;
      _keyword = '';
      _searchController.clear();
      _targetTypeFilter = null;
      _eventSourceFilter = null;
      _requestId = '';
      _requestIdController.clear();
      _operationKindFilter = null;
      _actorScopeFilter = _systemAnomalyMode
          ? 'system'
          : _anonymousMode
          ? 'anonymous'
          : _selectedActor == null
          ? null
          : 'user';
      _categoryFilter = null;
      _riskFilter = null;
      _outcomeFilter = null;
      _snapshotId = null;
    });
    if (_canLoad) _load(1);
  }

  /// createdAt ISO → 统一展示为北京时间。
  static String _fmtTime(String? iso) => DisplayDateTime.beijing(
    iso,
    fallback: '时间未知',
  ).replaceFirst('(北京)', '(北京时间)');

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
      cn = map[seg] ?? '业务报表';
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
      'view_sales_quote_detail' => '查看销售报价详情',
      'view_sales_order_detail' => '查看销售订单详情',
      'view_sales_shipment_detail' => '查看销售出货详情',
      'view_sales_other_shipment_detail' => '查看销售其他出库详情',
      'view_sales_return_detail' => '查看销售退货详情',
      'view_sales_quote_detail_history' => '查看销售报价历史单据',
      'view_sales_order_detail_history' => '查看销售订单历史单据',
      'view_sales_shipment_detail_history' => '查看销售出货历史单据',
      'view_sales_other_shipment_detail_history' => '查看销售其他出库历史单据',
      'view_sales_return_detail_history' => '查看销售退货历史单据',
      _ => '未登记操作名称',
    };
  }

  static String _resultLabel(String? r) {
    if (r == null || r.isEmpty) return '';
    return switch (r) {
      'success' => '成功',
      'failure' || 'failed' => '失败',
      'account_not_found' => '账号不存在',
      'bad_password' => '密码错误',
      'reuse_detected' => '检测到重用',
      'rate_limited' => '尝试过于频繁（已限流）',
      'locked' => '账号已锁定',
      'disabled' => '账号已停用',
      'expired' => '已过期',
      'invalid' => '凭证无效',
      'not_found' => '对象不存在',
      'denied' => '被拒绝',
      _ => '未知结果',
    };
  }

  Future<void> _refresh() async {
    if (!_canLoad) return;
    setState(() => _snapshotId = null);
    if (_sessionMode) {
      await _loadSessions(1);
    } else {
      await _load(1);
    }
  }

  void _switchView(bool sessions) {
    if (sessions == _sessionMode || (sessions && !_canUseSessionView)) return;
    _loadRequests.begin();
    _sessionLoadRequests.begin();
    setState(() {
      _preferSessionView = sessions;
      _snapshotId = null;
      _page = null;
      _summary = null;
      _sessionPage = null;
      _error = null;
      _sessionError = null;
      _loading = false;
      _sessionLoading = false;
      _pageNum = 1;
      _sessionPageNum = 1;
    });
    if (sessions) {
      _loadSessions(1);
    } else {
      _load(1);
    }
  }

  Map<String, dynamic> get _exportQueryParams => <String, dynamic>{
    if (_actionFilter != null) 'action': _actionFilter,
    if (_requestId.isEmpty &&
        !_anonymousMode &&
        !_systemAnomalyMode &&
        _selectedActor != null)
      'actorId': _selectedActor!.actorId,
    if (_keyword.trim().isNotEmpty) 'keyword': _keyword.trim(),
    if (_targetTypeFilter != null) 'targetType': _targetTypeFilter,
    if (_eventSourceFilter != null) 'eventSource': _eventSourceFilter,
    if (_requestId.trim().isNotEmpty) 'requestId': _requestId.trim(),
    if (_operationKindFilter != null) 'operationKind': _operationKindFilter,
    if (_actorScopeFilter != null) 'actorScope': _actorScopeFilter,
    'activityOnly': !_isRequestInvestigation,
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

  Future<void> _openDetail(AuditLogEntry entry) => showAuditLogDetailViewer(
    context: context,
    ref: ref,
    entry: entry,
    onLocateRequest: _locateRequest,
  );

  @override
  Widget build(BuildContext context) {
    // 返回即刷新：从其它页面回到审计中心时重拉当前页（保留筛选/页码），
    // 保证看到最新审计记录。本页路由为静态路径，直接用 RouteName 常量。
    ref.onPageResume(RouteName.adminAuditLogs, () {
      if (!_canLoad) return;
      _snapshotId = null;
      if (_sessionMode) {
        _loadSessions(_sessionPageNum, silent: true);
      } else {
        _load(_pageNum, silent: true);
      }
    });
    final items = _page?.items ?? const <AuditLogEntry>[];
    final sessions = _sessionPage?.items ?? const <AuditSessionSummary>[];
    final hasDrillDown =
        _riskFilter != null ||
        _outcomeFilter != null ||
        _categoryFilter != null;
    final viewportWidth = MediaQuery.sizeOf(context).width;
    return Scaffold(
      appBar: UtenAppBar(
        title: '审计中心',
        subtitle: viewportWidth >= 720 ? '人员行为、登录会话与安全异常调查' : null,
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
            enabled: _canLoad && _snapshotId != null,
            label: viewportWidth < 600 ? '导出' : '导出当前结果',
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _canLoad ? _refresh : null,
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final scrollView = RefreshIndicator(
                onRefresh: _refresh,
                child: CustomScrollView(
                  controller: _scrollController,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.only(top: UtenSpacing.s8),
                        child: AuditQueryScopeComposer(
                          selectedActor: _selectedActor,
                          anonymousMode: _anonymousMode,
                          systemAnomalyMode: _systemAnomalyMode,
                          dateRange: _dateRange,
                          requestIdController: _requestIdController,
                          requestInvestigation: _isRequestInvestigation,
                          loading: _activeLoading,
                          scopeApplied: _scopeApplied,
                          onPickActor: _pickActor,
                          onSelectAnonymous: _selectAnonymousScope,
                          onSelectSystemAnomaly: _selectSystemAnomalyScope,
                          onToday: () => _setDatePreset(1),
                          onYesterday: () {
                            if (_selectedActor == null &&
                                !_anonymousMode &&
                                !_systemAnomalyMode) {
                              context.appWarning('请先选择要查看的人员。');
                              return;
                            }
                            final today = ChinaDateTime.today();
                            final yesterday = today.subtract(
                              const Duration(days: 1),
                            );
                            setState(() {
                              _dateRange = DateTimeRange(
                                start: yesterday,
                                end: yesterday,
                              );
                              _invalidateScopeResults();
                            });
                          },
                          onSevenDays: () => _setDatePreset(7),
                          onThirtyDays: () => _setDatePreset(30),
                          onCustomDate: _pickDateRange,
                          onRunQuery: _applyScopeQuery,
                          onRequestIdChanged: _onRequestIdDraftChanged,
                          onRequestIdSubmitted: _onRequestIdSubmitted,
                          onClear: _clearScope,
                        ),
                      ),
                    ),
                    if (_canUseSessionView)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditViewModeSwitch(
                            sessionMode: _sessionMode,
                            loading: _activeLoading,
                            onSession: () => _switchView(true),
                            onEvents: () => _switchView(false),
                          ),
                        ),
                      ),
                    if (_canLoad && _sessionMode && _sessionPage != null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditSessionOverview(page: _sessionPage!),
                        ),
                      ),
                    if (_canLoad && !_sessionMode)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditMetricGrid(
                            summary: _summary,
                            selectedOperation: _operationKindFilter,
                            selectedRisk: _riskFilter,
                            selectedOutcome: _outcomeFilter,
                            selectedCategory: _categoryFilter,
                            onAll: () => _applyDrillDown(clear: true),
                            onRisk: () => _applyDrillDown(risk: 'risky'),
                            onCritical: () => _applyDrillDown(risk: 'critical'),
                            onFailure: () =>
                                _applyDrillDown(outcome: 'failure'),
                            onDataChange: () =>
                                _onOperationKindChanged('write'),
                          ),
                        ),
                      ),
                    if (_canLoad && !_sessionMode && _summaryFailed)
                      SliverToBoxAdapter(
                        child: ListTile(
                          leading: const Icon(Icons.info_outline),
                          title: Text(
                            AppLocalizations.of(
                              context,
                            ).auditSummaryUnavailable,
                          ),
                          trailing: TextButton(
                            onPressed: _loading ? null : () => _load(_pageNum),
                            child: Text(
                              AppLocalizations.of(context).auditSummaryRetry,
                            ),
                          ),
                        ),
                      ),
                    if (_canLoad && !_sessionMode)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditFilterPanel(
                            searchController: _searchController,
                            actionFilter: _actionFilter,
                            operationKindFilter: _operationKindFilter,
                            targetTypeFilter: _targetTypeFilter,
                            eventSourceFilter: _eventSourceFilter,
                            categoryFilter: _categoryFilter,
                            riskFilter: _riskFilter,
                            outcomeFilter: _outcomeFilter,
                            actionChips: _actionChips,
                            operationChips: _operationChips,
                            targetTypeChips: _targetTypeChips,
                            eventSourceOptions: _eventSourceOptions,
                            categoryChips: _categoryChips,
                            onSearchChanged: _onSearchChanged,
                            onActionChanged: _onChipTap,
                            onOperationKindChanged: _onOperationKindChanged,
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
                            onClear: _resetFilters,
                          ),
                        ),
                      ),
                    if (_canLoad &&
                        !_sessionMode &&
                        _summary?.dailyTrend.isNotEmpty == true)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditTrendCard(
                            points: _summary!.dailyTrend,
                            rangeLabel: _isRequestInvestigation
                                ? '同一操作'
                                : _dateRangeLabel,
                          ),
                        ),
                      ),
                    if (_canLoad && !_sessionMode)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(
                            top: UtenSpacing.s24,
                            bottom: UtenSpacing.s8,
                          ),
                          child: _AuditListHeader(
                            total: _page?.total ?? 0,
                            hasDrillDown: hasDrillDown,
                            onClearDrillDown: () =>
                                _applyDrillDown(clear: true),
                          ),
                        ),
                      ),
                    if (_canLoad && _sessionMode)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(
                            top: UtenSpacing.s24,
                            bottom: UtenSpacing.s8,
                          ),
                          child: _AuditSessionListHeader(
                            total: _sessionPage?.total,
                            currentPage: _sessionPage?.page,
                            totalPages: _sessionPage?.totalPages,
                          ),
                        ),
                      ),
                    if (_canLoad && _activeLoading)
                      const SliverToBoxAdapter(
                        child: LinearProgressIndicator(),
                      ),
                    if (_canLoad && _sessionMode && _sessionError != null)
                      SliverToBoxAdapter(
                        child: _AuditErrorCard(
                          message: _sessionError!,
                          onRetry: () => _loadSessions(_sessionPageNum),
                        ),
                      )
                    else if (_canLoad &&
                        _sessionMode &&
                        _sessionLoading &&
                        sessions.isEmpty)
                      const SliverToBoxAdapter(
                        child: _AuditSessionLoadingList(),
                      )
                    else if (_canLoad &&
                        _sessionMode &&
                        !_sessionLoading &&
                        sessions.isEmpty)
                      SliverToBoxAdapter(
                        child: _AuditSessionEmptyCard(
                          onShowEvents: () => _switchView(false),
                        ),
                      )
                    else if (_canLoad && _sessionMode)
                      SliverList.separated(
                        itemCount: sessions.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UtenSpacing.s8),
                        itemBuilder: (context, index) {
                          final session = sessions[index];
                          return AuditSessionCard(
                            key: ValueKey(session.sessionId),
                            session: session,
                            onOpen: () => context.push(
                              RoutePath.adminAuditSession(
                                session.sessionId,
                                snapshotAuditId: _sessionPage!.snapshotAuditId,
                              ),
                              extra: session,
                            ),
                          );
                        },
                      ),
                    if (_canLoad &&
                        _sessionMode &&
                        _sessionPage != null &&
                        _sessionError == null)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: UtenSpacing.s20,
                          ),
                          child: _AuditPagination(
                            currentPage: _sessionPage!.page,
                            totalPages: _sessionPage!.totalPages,
                            loading: _sessionLoading,
                            onPageChanged: _loadSessions,
                          ),
                        ),
                      ),
                    if (_canLoad && !_sessionMode && _error != null)
                      SliverToBoxAdapter(
                        child: _AuditErrorCard(
                          message: _error!,
                          onRetry: () => _load(_pageNum),
                        ),
                      )
                    else if (_canLoad &&
                        !_sessionMode &&
                        !_loading &&
                        items.isEmpty)
                      SliverToBoxAdapter(
                        child: _AuditEmptyCard(onAdjustScope: _clearScope),
                      )
                    else if (_canLoad && !_sessionMode)
                      SliverList.separated(
                        itemCount: items.length,
                        separatorBuilder: (_, _) =>
                            const SizedBox(height: UtenSpacing.s8),
                        itemBuilder: (context, index) => _AuditEventTile(
                          entry: items[index],
                          onTap: () => _openDetail(items[index]),
                        ),
                      ),
                    if (_canLoad &&
                        !_sessionMode &&
                        _page != null &&
                        _error == null)
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
                    if (_error == null)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: UtenSpacing.s8),
                          child: _AuditRetentionHint(),
                        ),
                      ),
                    const SliverToBoxAdapter(
                      child: SizedBox(height: UtenSpacing.s32),
                    ),
                  ],
                ),
              );
              if (constraints.maxWidth < 720) return scrollView;
              return Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                interactive: true,
                child: scrollView,
              );
            },
          ),
        ),
      ),
    );
  }
}
