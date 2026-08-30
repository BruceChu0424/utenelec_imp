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
      var summary = _summary;
      if (requestedSnapshotId == null || summary == null) {
        summary = await repository.summary(
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
      }
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

  String get _queryScopeLabel {
    if (_isRequestInvestigation) return '同一操作';
    if (_systemAnomalyMode) return '系统异常 · $_dateRangeLabel';
    if (_anonymousMode) return '未识别访问 · $_dateRangeLabel';
    return '${_selectedActor?.primaryLabel ?? '未知人员'} · $_dateRangeLabel';
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
      _ => '其他操作',
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

  Future<AuditSessionEventPage> _loadSessionEvents(
    String sessionId, {
    String? cursorAt,
    int? cursorId,
    int? snapshotAuditId,
  }) => ref
      .read(auditLogRepositoryProvider)
      .sessionEvents(
        sessionId: sessionId,
        cursorAt: cursorAt,
        cursorId: cursorId,
        snapshotAuditId: snapshotAuditId,
      );

  Future<_AuditDetailBundle> _loadDetailBundle(AuditLogEntry entry) async {
    final repository = ref.read(auditLogRepositoryProvider);
    final detail = await repository.detail(entry.id);
    final requestId = detail.requestId?.trim();
    if (requestId == null || !_requestIdPattern.hasMatch(requestId)) {
      return _AuditDetailBundle(detail: detail);
    }
    try {
      final relatedPage = await repository.list(
        size: 100,
        requestId: requestId,
        activityOnly: false,
      );
      final databaseRows = relatedPage.items
          .where((row) => row.eventSource == 'database' && row.id != detail.id)
          .toList(growable: false);
      const detailLimit = 24;
      return _AuditDetailBundle(
        detail: detail,
        relatedChanges: databaseRows.take(detailLimit).toList(growable: false),
        relatedChangesTruncated:
            databaseRows.length > detailLimit ||
            relatedPage.total > relatedPage.items.length,
      );
    } catch (_) {
      return _AuditDetailBundle(
        detail: detail,
        relatedChangesError: '关联业务变化加载失败，可稍后重试打开详情。',
      );
    }
  }

  Future<void> _openDetail(AuditLogEntry entry) async {
    final width = MediaQuery.sizeOf(context).width;
    if (width < 720) {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (sheetContext) => FractionallySizedBox(
          heightFactor: 0.92,
          child: _AuditDetailPanel(
            loader: () => _loadDetailBundle(entry),
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
    final panelWidth = (width * 0.56).clamp(640.0, 900.0).toDouble();
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭审计详情',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, _) => Align(
        alignment: Alignment.centerRight,
        child: Material(
          color: Theme.of(context).colorScheme.surface,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.horizontal(
              left: Radius.circular(20),
            ),
            side: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          child: SizedBox(
            width: panelWidth,
            height: double.infinity,
            child: _AuditDetailPanel(
              loader: () => _loadDetailBundle(entry),
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
            enabled: _canLoad && _snapshotId != null,
            label: '导出当前结果',
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
                    if (!_canLoad)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditStartGuide(),
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
                    if (_canLoad && !_sessionMode)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: _AuditMetricGrid(
                            summary: _summary,
                            scopeLabel: _isRequestInvestigation
                                ? '同一操作的完整证据'
                                : _queryScopeLabel,
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
                            scopeLabel: _isRequestInvestigation
                                ? '同一操作'
                                : _queryScopeLabel,
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
                            total: _sessionPage?.total ?? 0,
                            scopeLabel: _queryScopeLabel,
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
                            snapshotAuditId: _sessionPage!.snapshotAuditId,
                            loadEvents:
                                ({
                                  String? cursorAt,
                                  int? cursorId,
                                  int? snapshotAuditId,
                                }) => _loadSessionEvents(
                                  session.sessionId,
                                  cursorAt: cursorAt,
                                  cursorId: cursorId,
                                  snapshotAuditId: snapshotAuditId,
                                ),
                            onOpenEvent: _openDetail,
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

/// 日志保留策略提示文案（读公共设置；失败时退化为通用说明，不阻塞页面）。
final _auditRetentionHintProvider = FutureProvider.autoDispose<String>((
  ref,
) async {
  try {
    final settings = await ref.watch(publicSettingsRepositoryProvider).fetch();
    return '日志分为在线与冷归档两段保留；本页面只查询在线记录。超过在线期后需走受控调查/恢复流程查询归档；'
        '总保留期最长 ${settings.auditReceiptRetentionMonths} 个月，在线与归档分段以系统设置为准。';
  } catch (_) {
    return '本页面只查询在线审计记录；超过在线期的记录进入冷归档，'
        '需要通过受控调查/恢复流程查询。';
  }
});

/// 列表底部的保留策略说明，让"为什么查不到很早的日志"有明确答案。
class _AuditRetentionHint extends ConsumerWidget {
  const _AuditRetentionHint();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hint = ref.watch(_auditRetentionHintProvider);
    return hint.maybeWhen(
      data: (text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.auto_delete_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _AuditStartGuide extends StatelessWidget {
  const _AuditStartGuide();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final copy = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '先确定调查对象和时间',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '页面不会预先加载全部日志。完成上方两步后，只查询所选调查范围在北京时间区间内的记录。',
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
                    label: '按范围精确查询',
                    type: UtenStatusBadgeType.success,
                    icon: Icons.fact_check_outlined,
                  ),
                  UtenStatusBadge(
                    label: '单次最多 31 天',
                    type: UtenStatusBadgeType.warning,
                    icon: Icons.policy_outlined,
                  ),
                  UtenStatusBadge(
                    label: '每页仅 20 条',
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
    required this.scopeLabel,
    required this.selectedOperation,
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
  final String scopeLabel;
  final String? selectedOperation;
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
            selectedOperation == null &&
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
        '写操作',
        summary?.dataChangeCount,
        Icons.data_object_rounded,
        theme.colorScheme.secondary,
        selectedOperation == 'write',
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
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '当前调查范围概览',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              scopeLabel,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final card in cards)
                  SizedBox(
                    width: width,
                    child: _AuditMetricCard(spec: card),
                  ),
              ],
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
    required this.actionFilter,
    required this.operationKindFilter,
    required this.targetTypeFilter,
    required this.eventSourceFilter,
    required this.categoryFilter,
    required this.riskFilter,
    required this.outcomeFilter,
    required this.actionChips,
    required this.operationChips,
    required this.targetTypeChips,
    required this.eventSourceOptions,
    required this.categoryChips,
    required this.onSearchChanged,
    required this.onActionChanged,
    required this.onOperationKindChanged,
    required this.onTargetTypeChanged,
    required this.onEventSourceChanged,
    required this.onCategoryChanged,
    required this.onRiskChanged,
    required this.onOutcomeChanged,
    required this.onClear,
  });

  final TextEditingController searchController;
  final String? actionFilter;
  final String? operationKindFilter;
  final String? targetTypeFilter;
  final String? eventSourceFilter;
  final String? categoryFilter;
  final String? riskFilter;
  final String? outcomeFilter;
  final List<(String, String?)> actionChips;
  final List<(String, String?)> operationChips;
  final List<(String, String?)> targetTypeChips;
  final List<(String, String?)> eventSourceOptions;
  final List<(String, String?)> categoryChips;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<String?> onActionChanged;
  final ValueChanged<String?> onOperationKindChanged;
  final ValueChanged<String?> onTargetTypeChanged;
  final ValueChanged<String?> onEventSourceChanged;
  final ValueChanged<String?> onCategoryChanged;
  final ValueChanged<String?> onRiskChanged;
  final ValueChanged<String?> onOutcomeChanged;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.filter_alt_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '进一步筛选',
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
          Semantics(
            key: const ValueKey('audit-keyword-field'),
            textField: true,
            label: '在当前人员和日期内搜索',
            child: UtenSearchBar(
              hint: '搜索业务编号、对象编号或操作关联编号',
              controller: searchController,
              onChanged: onSearchChanged,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '搜索只在当前人员和所选日期内生效，不会扩大查询范围。',
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
                label: '动作分类',
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
  const _AuditTrendCard({required this.points, required this.rangeLabel});

  final List<AuditDailyPoint> points;
  final String rangeLabel;

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
      label: '$rangeLabel 操作趋势，共 $total 次操作，其中 $risks 次风险行为',
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
                    '$rangeLabel 操作趋势',
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

class _AuditViewModeSwitch extends StatelessWidget {
  const _AuditViewModeSwitch({
    required this.sessionMode,
    required this.loading,
    required this.onSession,
    required this.onEvents,
  });

  final bool sessionMode;
  final bool loading;
  final VoidCallback onSession;
  final VoidCallback onEvents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final selector = Semantics(
            label: sessionMode ? '当前按用户会话查看' : '当前按事件明细查看',
            child: SegmentedButton<bool>(
              key: const ValueKey('audit-view-mode'),
              segments: [
                ButtonSegment<bool>(
                  value: true,
                  enabled: !loading,
                  icon: const Icon(Icons.login_rounded),
                  label: const Text('用户会话'),
                ),
                ButtonSegment<bool>(
                  value: false,
                  enabled: !loading,
                  icon: const Icon(Icons.list_alt_rounded),
                  label: const Text('事件明细'),
                ),
              ],
              selected: {sessionMode},
              onSelectionChanged: (selection) {
                if (selection.single) {
                  onSession();
                } else {
                  onEvents();
                }
              },
            ),
          );
          final description = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '查看方式',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                sessionMode ? '每次建立会话一张卡，展开后再加载该会话的人工操作。' : '按单条事件筛选、分页和调查。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 620) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                description,
                const SizedBox(height: UtenSpacing.s12),
                selector,
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: description),
              const SizedBox(width: UtenSpacing.s16),
              selector,
            ],
          );
        },
      ),
    );
  }
}

class _AuditSessionListHeader extends StatelessWidget {
  const _AuditSessionListHeader({
    required this.total,
    required this.scopeLabel,
  });

  final int total;
  final String scopeLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '用户会话 · $total 次',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          '$scopeLabel · 卡片显示完整会话起止时间 · 全部为北京时间',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

class _AuditSessionEmptyCard extends StatelessWidget {
  const _AuditSessionEmptyCard({required this.onShowEvents});

  final VoidCallback onShowEvents;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          children: [
            Icon(
              Icons.history_toggle_off_rounded,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text('该范围没有可识别的登录会话', style: theme.textTheme.titleMedium),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '旧日志尚无会话标识，可切换事件视图。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            OutlinedButton.icon(
              key: const ValueKey('audit-session-empty-show-events'),
              onPressed: onShowEvents,
              icon: const Icon(Icons.list_alt_rounded),
              label: const Text('切换事件视图'),
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
    required this.scopeLabel,
    required this.hasDrillDown,
    required this.onClearDrillDown,
  });

  final int total;
  final String scopeLabel;
  final bool hasDrillDown;
  final VoidCallback onClearDrillDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '操作记录 · $total 条',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                '$scopeLabel · 全部为北京时间',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
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
    final actor = AuditEventPresentation.actorLabel(
      actorDisplay: entry.actorDisplay,
      actorName: entry.actorName,
      actorAccount: entry.actorAccount,
    );
    final department = entry.actorDepartment?.trim();
    final actorContext = department?.isNotEmpty == true
        ? '$actor · $department'
        : actor;
    final time = _AdminAuditLogPageState._fmtTime(entry.createdAt);
    final action = entry.actionLabel?.trim().isNotEmpty == true
        ? entry.actionLabel!.trim()
        : _AdminAuditLogPageState._actionLabel(entry.action);
    final object = entry.objectLabel?.trim().isNotEmpty == true
        ? entry.objectLabel!.trim()
        : _objectTypeLabel(entry.targetType);
    final salesViewNarrative = AuditEventPresentation.salesViewNarrative(
      action: entry.action,
      targetName: entry.targetName,
    );
    final summary =
        salesViewNarrative ??
        (entry.summary?.trim().isNotEmpty == true
            ? entry.summary!
            : '$action · $object');
    final safeTargetName = AuditEventPresentation.safeBusinessReference(
      entry.targetName,
    );
    final detailBits = <String>[
      if (salesViewNarrative == null && safeTargetName != null)
        '对象 $safeTargetName',
      if (entry.pageLabel?.trim().isNotEmpty == true) '位置 ${entry.pageLabel}',
      if (entry.deviceLabel?.trim().isNotEmpty == true &&
          entry.deviceLabel != '未提供设备信息')
        '设备 ${entry.deviceLabel}',
    ];
    final failed = _isAuditFailure(entry.result, entry.statusCode);
    final showRisk = entry.riskLevel != 'low';

    Widget outcomeIndicator() {
      if (failed) {
        return _AuditResultBadge(
          result: entry.result,
          resultLabel: entry.resultLabel,
          statusCode: entry.statusCode,
        );
      }
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.check_circle_outline_rounded,
            size: 16,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s4),
          Text(
            _auditOutcomeLabel(
              entry.result,
              entry.resultLabel,
              entry.statusCode,
            ),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      );
    }

    return Semantics(
      button: true,
      excludeSemantics: true,
      label:
          '$actor，在$time，$summary，'
          '${_auditOutcomeLabel(entry.result, entry.resultLabel, entry.statusCode)}，点击查看详情',
      child: UtenCard(
        onTap: onTap,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final icon = _AuditRiskIcon(level: entry.riskLevel);
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.person_outline_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        actorContext,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Row(
                  children: [
                    Icon(
                      Icons.schedule_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    Expanded(
                      child: Text(
                        time,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  summary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.45,
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
                if (showRisk) _AuditRiskBadge(level: entry.riskLevel),
                if (showRisk) const SizedBox(height: UtenSpacing.s8),
                outcomeIndicator(),
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
                      if (showRisk) _AuditRiskBadge(level: entry.riskLevel),
                      if (showRisk) const SizedBox(width: UtenSpacing.s8),
                      outcomeIndicator(),
                      const Spacer(),
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

String _shortId(String value) => value.length <= 13
    ? value
    : '${value.substring(0, 8)}…${value.substring(value.length - 4)}';

String _objectTypeLabel(String? value) => switch (value?.trim()) {
  'goods' => '货品',
  'material_categories' => '货品分类',
  'clients' => '客户',
  'suppliers' => '供应商',
  'purchase_orders' => '采购订单',
  'sales_quotes' => '销售报价',
  'sales_orders' => '销售订单',
  'sales_shipments' => '销售出货',
  'sales_other_shipments' => '销售其他出库',
  'sales_returns' => '销售退货',
  'subcontract_orders' => '委外订单',
  'production_plans' => '生产计划',
  'production_execution_segments' => '生产执行分段',
  'employees' => '员工档案',
  'departments' => '部门',
  'users' || 'user_accounts' => '用户账号',
  'system_settings' => '系统设置',
  _ => '其他业务对象',
};

bool _isAuditFailure(String? result, int? statusCode) {
  if (statusCode != null && statusCode >= 400) return true;
  final primaryCode = _auditPrimaryResultCode(result);
  if (primaryCode == null) return false;
  return primaryCode != 'success' && primaryCode != 'succeeded';
}

String? _auditPrimaryResultCode(String? result) {
  final normalized = result?.trim().toLowerCase();
  if (normalized == null || normalized.isEmpty) return null;
  final separator = normalized.indexOf(';');
  final primary = separator < 0
      ? normalized
      : normalized.substring(0, separator).trim();
  return primary.isEmpty ? null : primary;
}

bool _isAuditSuccess(String? result, int? statusCode) {
  if (statusCode != null && statusCode >= 400) return false;
  final primaryCode = _auditPrimaryResultCode(result);
  return primaryCode == 'success' || primaryCode == 'succeeded';
}

String _auditOutcomeLabel(
  String? result,
  String? resultLabel,
  int? statusCode,
) {
  final translated = resultLabel?.trim();
  if (_isAuditFailure(result, statusCode)) {
    if (translated?.isNotEmpty == true && !translated!.contains('成功')) {
      return translated;
    }
    final fallback = _AdminAuditLogPageState._resultLabel(
      _auditPrimaryResultCode(result),
    );
    return fallback.isNotEmpty && fallback != '成功' && fallback != '未知结果'
        ? fallback
        : '失败';
  }
  if (translated?.isNotEmpty == true) return translated!;
  if ((statusCode != null && statusCode >= 200 && statusCode < 400) ||
      _isAuditSuccess(result, statusCode)) {
    return '成功';
  }
  return '未知结果';
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
  const _AuditResultBadge({
    required this.result,
    required this.statusCode,
    this.resultLabel,
  });

  final String? result;
  final String? resultLabel;
  final int? statusCode;

  @override
  Widget build(BuildContext context) {
    final failed = _isAuditFailure(result, statusCode);
    final label = _auditOutcomeLabel(result, resultLabel, statusCode);
    final succeeded =
        !failed && (_isAuditSuccess(result, statusCode) || label == '成功');
    return UtenStatusBadge(
      label: label,
      type: failed
          ? UtenStatusBadgeType.danger
          : succeeded
          ? UtenStatusBadgeType.success
          : UtenStatusBadgeType.info,
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
  const _AuditEmptyCard({required this.onAdjustScope});

  final VoidCallback onAdjustScope;

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
            '可重置进一步筛选，或重新选择人员和日期区间。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          OutlinedButton.icon(
            onPressed: onAdjustScope,
            icon: const Icon(Icons.manage_search_outlined),
            label: const Text('重新选择人员和日期'),
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

class _AuditDetailBundle {
  const _AuditDetailBundle({
    required this.detail,
    this.relatedChanges = const [],
    this.relatedChangesError,
    this.relatedChangesTruncated = false,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
}

class _AuditDetailPanel extends StatefulWidget {
  const _AuditDetailPanel({
    required this.loader,
    required this.onClose,
    required this.onLocateRequest,
  });

  final Future<_AuditDetailBundle> Function() loader;
  final VoidCallback onClose;
  final ValueChanged<String> onLocateRequest;

  @override
  State<_AuditDetailPanel> createState() => _AuditDetailPanelState();
}

class _AuditDetailPanelState extends State<_AuditDetailPanel> {
  late Future<_AuditDetailBundle> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.loader();
  }

  void _reload() {
    setState(() => _future = widget.loader());
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_AuditDetailBundle>(
      future: _future,
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
              _AuditDetailHeader(title: '审计详情', onClose: widget.onClose),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        message,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      OutlinedButton.icon(
                        onPressed: _reload,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        return _AuditDetailContent(
          detail: snapshot.data!.detail,
          relatedChanges: snapshot.data!.relatedChanges,
          relatedChangesError: snapshot.data!.relatedChangesError,
          relatedChangesTruncated: snapshot.data!.relatedChangesTruncated,
          onRetryRelatedChanges: _reload,
          onClose: widget.onClose,
          onLocateRequest: widget.onLocateRequest,
        );
      },
    );
  }
}

class _AuditDetailContent extends StatelessWidget {
  const _AuditDetailContent({
    required this.detail,
    required this.relatedChanges,
    required this.relatedChangesTruncated,
    required this.onRetryRelatedChanges,
    required this.onClose,
    required this.onLocateRequest,
    this.relatedChangesError,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
  final VoidCallback onRetryRelatedChanges;
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
                    AuditEventPresentation.salesViewNarrative(
                      action: detail.action,
                      targetName: detail.targetName,
                    ) ??
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
                  Tab(icon: Icon(Icons.troubleshoot_rounded), text: '排查信息'),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              Expanded(
                child: TabBarView(
                  children: [
                    _AuditOverviewTab(detail: detail),
                    _AuditChangeTab(
                      detail: detail,
                      relatedChanges: relatedChanges,
                      relatedChangesError: relatedChangesError,
                      relatedChangesTruncated: relatedChangesTruncated,
                      onRetryRelatedChanges: onRetryRelatedChanges,
                    ),
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

/// 概览页：一张"操作叙事卡"按 谁 → 何时/在哪 → 做了什么 → 改了什么 的顺序讲完整事件，
/// 再配风险说明与排查线索。信息按"读故事"的顺序组织，而不是按数据库字段罗列。
class _AuditOverviewTab extends StatelessWidget {
  const _AuditOverviewTab({required this.detail});

  final AuditLogDetail detail;

  /// 结果优先用后端翻译好的中文（如 密码错误），兜底本地映射。
  static String _outcomeText(AuditLogDetail detail) {
    final label = detail.resultLabel?.trim();
    if (label?.isNotEmpty == true) return label!;
    final local = _AdminAuditLogPageState._resultLabel(detail.result);
    if (local.isNotEmpty) return local;
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _AuditStoryCard(detail: detail),
        const SizedBox(height: UtenSpacing.s12),
        _AuditRiskCard(
          riskLevel: detail.riskLevel,
          riskReason: detail.riskReason,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _AuditEnvironmentCard(detail: detail),
      ],
    );
  }
}

/// 操作叙事卡：回答"谁、在几点、在哪个页面、做了什么、对象是哪张单据、具体改了什么"。
class _AuditStoryCard extends StatelessWidget {
  const _AuditStoryCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final displayName = AuditEventPresentation.actorLabel(
      actorDisplay: detail.actorDisplay,
      actorName: detail.actorName,
      actorAccount: detail.actorAccount,
    );
    final initial = displayName.isNotEmpty ? displayName.characters.first : '?';
    final headline =
        AuditEventPresentation.salesViewNarrative(
          action: detail.action,
          targetName: detail.targetName,
        ) ??
        (detail.summary?.trim().isNotEmpty == true
            ? detail.summary!
            : detail.actionLabel?.trim().isNotEmpty == true
            ? detail.actionLabel!
            : _AdminAuditLogPageState._actionLabel(detail.action));
    final objectText = _objectText(detail);
    final changes = _parseChangeEntries(detail);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 卡片标题 + 操作结果 ──────────────────────────────
          Row(
            children: [
              Icon(Icons.fact_check_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '这次操作做了什么',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // ── 谁 ─────────────────────────────────────────────
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Text(
                  initial,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (detail.actorName?.trim().isNotEmpty == true &&
                        detail.actorAccount?.trim().isNotEmpty == true)
                      Text(
                        '账号 ${detail.actorAccount}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              _AuditResultBadge(
                result: detail.result,
                resultLabel: detail.resultLabel,
                statusCode: detail.statusCode,
              ),
            ],
          ),
          if (detail.actorDepartment?.trim().isNotEmpty == true ||
              detail.actorPosition?.trim().isNotEmpty == true) ...[
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if (detail.actorDepartment?.trim().isNotEmpty == true)
                  _OrgChip(
                    icon: Icons.apartment_outlined,
                    label: '部门',
                    value: detail.actorDepartment!,
                  ),
                if (detail.actorPosition?.trim().isNotEmpty == true)
                  _OrgChip(
                    icon: Icons.badge_outlined,
                    label: '职位',
                    value: detail.actorPosition!,
                  ),
              ],
            ),
          ],
          const Divider(height: UtenSpacing.s24),
          // ── 何时 / 在哪 ─────────────────────────────────────
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              _AuditContextChip(
                icon: Icons.schedule_rounded,
                text: _AdminAuditLogPageState._fmtTime(detail.createdAt),
              ),
              if (detail.pageLabel?.trim().isNotEmpty == true)
                _AuditContextChip(
                  icon: Icons.web_asset_outlined,
                  text: detail.pageLabel!,
                ),
              _AuditContextChip(
                icon: Icons.storage_outlined,
                text: _sourceLabel(detail.eventSource),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // ── 做了什么：完整中文句子（动作 + 对象 + 单号 + 关键变化）──
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(UtenSpacing.s12, 2, 0, 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 3),
              ),
            ),
            child: Text(
              headline,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
          ),
          // ── 对象：哪张单据 / 哪个档案 ────────────────────────
          if (objectText != null) ...[
            const SizedBox(height: UtenSpacing.s12),
            Row(
              children: [
                Icon(
                  Icons.sell_outlined,
                  size: 18,
                  color: theme.colorScheme.tertiary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  '操作对象',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Flexible(
                  child: Text(
                    objectText,
                    overflow: TextOverflow.ellipsis,
                    maxLines: 2,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ],
          // ── 具体变更：什么字段、从什么值改成了什么值 ──────────
          if (changes.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s16),
            Text(
              '具体变更',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            ...changes.map((entry) => _AuditChangeRow(entry: entry)),
          ],
        ],
      ),
    );
  }

  static String? _objectText(AuditLogDetail detail) {
    final salesObject = AuditEventPresentation.salesViewObjectText(
      action: detail.action,
      targetName: detail.targetName,
    );
    if (salesObject != null) return salesObject;
    final label = detail.objectLabel?.trim().isNotEmpty == true
        ? detail.objectLabel!
        : _objectTypeLabel(detail.targetType);
    final name = AuditEventPresentation.safeBusinessReference(
      detail.targetName,
    );
    if (label.isEmpty) {
      return name?.isNotEmpty == true ? name : null;
    }
    return name?.isNotEmpty == true ? '$label · $name' : label;
  }
}

/// 风险说明卡：等级徽标 + 风险原因 + 免责说明。
class _AuditRiskCard extends StatelessWidget {
  const _AuditRiskCard({required this.riskLevel, required this.riskReason});

  final String riskLevel;
  final String? riskReason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _riskColor(context, riskLevel);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _AuditRiskIcon(level: riskLevel),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AuditRiskBadge(level: riskLevel),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  riskReason ?? '未提供风险说明',
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
    );
  }
}

/// 业务语义卡：概览只保留普通核查人员需要的中文信息。
class _AuditEnvironmentCard extends StatelessWidget {
  const _AuditEnvironmentCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.travel_explore_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '操作说明',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(
                label: '做了什么',
                value:
                    AuditEventPresentation.salesViewActionLabel(
                      detail.action,
                    ) ??
                    detail.actionLabel ??
                    _AdminAuditLogPageState._actionLabel(detail.action),
              ),
              _AuditFact(
                label: '结果',
                value: _AuditOverviewTab._outcomeText(detail),
              ),
              _AuditFact(
                label: '事件类型',
                value: _categoryLabel(detail.eventCategory),
              ),
              if (detail.pageLabel?.trim().isNotEmpty == true)
                _AuditFact(label: '操作位置', value: detail.pageLabel!),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '操作关联编号、网络地址、请求路径和原始编码统一收在“排查信息”中。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 时间 / 页面 / 记录来源小标签（"何时、在哪"的上下文）。
class _AuditContextChip extends StatelessWidget {
  const _AuditContextChip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: UtenRadius.smAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s4),
          Flexible(
            child: Text(
              text,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一条具体变更：字段名 + [旧值] → [新值]；非字段说明（如"共填写 N 项信息"）整行展示。
class _AuditChangeRow extends StatelessWidget {
  const _AuditChangeRow({required this.entry});

  final _AuditChangeEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (entry.field == null) {
      return Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Container(
                width: 5,
                height: 5,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                entry.info ?? '',
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              entry.field!,
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Wrap(
              spacing: UtenSpacing.s4,
              runSpacing: UtenSpacing.s4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _AuditValueChip(value: entry.oldValue ?? '空', changed: false),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                _AuditValueChip(value: entry.newValue ?? '空', changed: true),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 变更值胶囊：旧值灰底、新值主题色底，让"改成什么"一眼突出。
class _AuditValueChip extends StatelessWidget {
  const _AuditValueChip({required this.value, required this.changed});

  final String value;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final background = changed
        ? theme.colorScheme.primaryContainer
        : theme.colorScheme.surfaceContainerHighest;
    final foreground = changed
        ? theme.colorScheme.onPrimaryContainer
        : theme.colorScheme.onSurfaceVariant;
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.smAll,
      ),
      child: Text(
        // 时间戳等原始值统一经字段字典可读化(ISO → yyyy-MM-dd HH:mm(北京时间))
        AuditFieldLabels.valueOf(value),
        overflow: TextOverflow.ellipsis,
        maxLines: 1,
        style: theme.textTheme.bodySmall?.copyWith(
          color: foreground,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

/// 后端 changeSummary（"字段：旧 → 新；…"，分号分隔）解析结果。
class _AuditChangeEntry {
  const _AuditChangeEntry._({
    this.field,
    this.oldValue,
    this.newValue,
    this.info,
  });

  const _AuditChangeEntry.ofField(
    String field,
    String oldValue,
    String newValue,
  ) : this._(field: field, oldValue: oldValue, newValue: newValue);

  const _AuditChangeEntry.ofNote(String info) : this._(info: info);

  /// 中文字段名；为 null 表示这是一条说明行（info 有值）。
  final String? field;
  final String? oldValue;
  final String? newValue;
  final String? info;
}

List<_AuditChangeEntry> _parseChangeEntries(AuditLogDetail detail) {
  return _parseChangeSummary(detail.changeSummary);
}

List<_AuditChangeEntry> _parseChangeSummary(String? value) {
  final raw = value?.trim();
  if (raw == null || raw.isEmpty) return const [];
  return raw
      .split('；')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) {
        // "字段：旧值 → 新值"：第一个冒号前是字段名，最后一个" → "两侧是前后值
        final colon = line.indexOf('：');
        final arrow = line.indexOf(' → ');
        if (colon > 0 && arrow > colon) {
          final rest = line.substring(colon + 1);
          final separator = rest.lastIndexOf(' → ');
          if (separator > 0) {
            return _AuditChangeEntry.ofField(
              line.substring(0, colon),
              rest.substring(0, separator),
              rest.substring(separator + 3),
            );
          }
        }
        return _AuditChangeEntry.ofNote(line);
      })
      .toList();
}

/// 部门/职位小标签。
class _OrgChip extends StatelessWidget {
  const _OrgChip({required this.icon, this.label, this.value});

  final IconData icon;
  final String? label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s8,
        vertical: 4,
      ),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text(
            '${label ?? ''} ${value ?? ''}'.trim(),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditChangeTab extends ConsumerStatefulWidget {
  const _AuditChangeTab({
    required this.detail,
    required this.relatedChanges,
    required this.relatedChangesTruncated,
    required this.onRetryRelatedChanges,
    this.relatedChangesError,
  });

  final AuditLogDetail detail;
  final List<AuditLogEntry> relatedChanges;
  final String? relatedChangesError;
  final bool relatedChangesTruncated;
  final VoidCallback onRetryRelatedChanges;

  @override
  ConsumerState<_AuditChangeTab> createState() => _AuditChangeTabState();
}

class _AuditChangeTabState extends ConsumerState<_AuditChangeTab> {
  bool _namesRequested = false;

  Map<String, dynamic> _decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 把快照里"长得像 UUID"的值按字段语义批量预解析成名称（仓库/货品/员工…）。
  Future<void> _ensureNames(
    Map<String, dynamic> before,
    Map<String, dynamic> after,
  ) async {
    if (_namesRequested) return;
    _namesRequested = true;
    final service = ref.read(masterNameServiceProvider);
    final goodsIds = <String>{};
    final employeeIds = <String>{};
    for (final entry in [...before.entries, ...after.entries]) {
      for (final value in [entry.value, after[entry.key]]) {
        if (!AuditFieldLabels.looksLikeUuid(value)) continue;
        final kind = _refKindOf(entry.key);
        if (kind == _RefKind.goods) goodsIds.add(value as String);
        if (kind == _RefKind.employee) employeeIds.add(value as String);
      }
    }
    try {
      await service.ensureLoaded();
      await Future.wait([
        service.loadGoodsNames(goodsIds),
        service.loadEmployeeNames(employeeIds.toList()),
      ]);
      if (mounted) setState(() {});
    } catch (_) {
      // 名称解析是辅助信息，失败时保持短 ID 展示。
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final before = _decode(widget.detail.beforeJson);
    final after = _decode(widget.detail.afterJson);
    final keys = {...before.keys, ...after.keys}.toList()..sort();
    final changed = keys
        .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
        .toList(growable: false);
    if (changed.isNotEmpty && !_namesRequested) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureNames(before, after),
      );
    }
    final service = ref.watch(masterNameServiceProvider);
    final related = widget.relatedChanges;
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                related.isNotEmpty
                    ? '本次操作产生 ${related.length} 组业务变化'
                    : changed.isEmpty
                    ? '没有字段级快照'
                    : '共 ${changed.length} 个字段发生变化',
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
        if (widget.relatedChangesError != null) ...[
          _AuditErrorCard(
            message: widget.relatedChangesError!,
            onRetry: widget.onRetryRelatedChanges,
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (related.isNotEmpty) ...[
          for (final change in related) ...[
            _AuditRelatedChangeCard(entry: change),
            const SizedBox(height: UtenSpacing.s8),
          ],
          if (widget.relatedChangesTruncated)
            Text(
              '关联变化较多，本页仅展示前 24 组；可按操作关联编号进一步排查。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        if (changed.isEmpty && related.isEmpty)
          UtenCard(
            child: Text(
              '这条记录可能是读取或安全事件，也可能没有产生字段变化。可在“排查信息”中查看关联线索。',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            ),
          )
        else if (changed.isNotEmpty) ...[
          Text(
            related.isEmpty ? '字段变化' : '当前记录的字段快照',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var index = 0; index < changed.length; index++) ...[
                  _AuditDiffRow(
                    field: AuditFieldLabels.labelOf(changed[index]),
                    before: _displayValue(
                      service,
                      changed[index],
                      before[changed[index]],
                    ),
                    after: _displayValue(
                      service,
                      changed[index],
                      after[changed[index]],
                    ),
                  ),
                  if (index != changed.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        ],
        if (widget.detail.beforeJson?.trim().isNotEmpty == true ||
            widget.detail.afterJson?.trim().isNotEmpty == true) ...[
          const SizedBox(height: UtenSpacing.s12),
          _AuditJsonExpansion(
            label: '查看变更前原始数据',
            rawJson: widget.detail.beforeJson,
          ),
          const SizedBox(height: UtenSpacing.s8),
          _AuditJsonExpansion(
            label: '查看变更后原始数据',
            rawJson: widget.detail.afterJson,
          ),
        ],
      ],
    );
  }

  /// UUID 值 → "名称（短ID）"；无法解析时缩短展示；其余值翻译布尔/空。
  static String _displayValue(
    MasterNameService service,
    String field,
    dynamic value,
  ) {
    if (AuditFieldLabels.looksLikeUuid(value)) {
      final id = value as String;
      final resolved = _resolveRef(service, field, id);
      return resolved == null ? _shortId(id) : '$resolved(${_shortId(id)})';
    }
    return AuditFieldLabels.valueOf(value);
  }

  static String? _resolveRef(
    MasterNameService service,
    String field,
    String id,
  ) {
    String? pick(String name) => name == '—' || name.isEmpty ? null : name;
    return switch (_refKindOf(field)) {
      _RefKind.warehouse => pick(service.warehouse(id)),
      _RefKind.currency => pick(service.currency(id)),
      _RefKind.color => pick(service.color(id)),
      _RefKind.unit => pick(service.unit(id)),
      _RefKind.goods => pick(service.goods(id)),
      _RefKind.supplier => pick(service.supplier(id)),
      _RefKind.department => pick(service.department(id)),
      _RefKind.employee => pick(service.employee(id)),
      _RefKind.unknown => null,
    };
  }

  static _RefKind _refKindOf(String field) {
    final key = field.toLowerCase();
    if (key.contains('warehouse')) return _RefKind.warehouse;
    if (key.contains('currency')) return _RefKind.currency;
    if (key.contains('color')) return _RefKind.color;
    if (key.contains('unit_id') || key.endsWith('_unit')) return _RefKind.unit;
    if (key.contains('goods') || key.contains('material') || key == 'item_id') {
      return _RefKind.goods;
    }
    if (key.contains('supplier')) return _RefKind.supplier;
    if (key.contains('department')) return _RefKind.department;
    if (key.contains('employee') ||
        key.contains('supervisor') ||
        key.endsWith('_by') ||
        key == 'user_id' ||
        key == 'operator_id' ||
        key == 'maker_id') {
      return _RefKind.employee;
    }
    return _RefKind.unknown;
  }
}

class _AuditRelatedChangeCard extends ConsumerStatefulWidget {
  const _AuditRelatedChangeCard({required this.entry});

  final AuditLogEntry entry;

  @override
  ConsumerState<_AuditRelatedChangeCard> createState() =>
      _AuditRelatedChangeCardState();
}

class _AuditRelatedChangeCardState
    extends ConsumerState<_AuditRelatedChangeCard> {
  Future<AuditLogDetail>? _detailFuture;

  void _loadDetail() {
    setState(() {
      _detailFuture = ref
          .read(auditLogRepositoryProvider)
          .detail(widget.entry.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = widget.entry;
    final previewEntries = _parseChangeSummary(entry.changeSummary);
    final object = entry.objectLabel?.trim().isNotEmpty == true
        ? entry.objectLabel!.trim()
        : _objectTypeLabel(entry.targetType);
    final name = entry.targetName?.trim();
    return UtenCard(
      padding: EdgeInsets.zero,
      child: ExpansionTile(
        key: ValueKey('audit-related-change-${entry.id}'),
        onExpansionChanged: (expanded) {
          if (expanded && _detailFuture == null) _loadDetail();
        },
        title: Text(
          name?.isNotEmpty == true ? '$object · $name' : object,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: entry.summary?.trim().isNotEmpty == true
            ? Text(entry.summary!, maxLines: 2, overflow: TextOverflow.ellipsis)
            : const Text('已记录脱敏业务变化'),
        children: [
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (previewEntries.isNotEmpty) ...[
                  Text(
                    '变化摘要',
                    style: theme.textTheme.labelLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  for (final preview in previewEntries)
                    _AuditChangeRow(entry: preview),
                  const SizedBox(height: UtenSpacing.s12),
                ],
                FutureBuilder<AuditLogDetail>(
                  future: _detailFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          LinearProgressIndicator(minHeight: 2),
                          SizedBox(height: UtenSpacing.s8),
                          Text('正在加载这一组的完整字段详情…'),
                        ],
                      );
                    }
                    if (snapshot.hasError || snapshot.data == null) {
                      return Row(
                        children: [
                          Expanded(
                            child: Text(
                              '这组字段详情加载失败，可单独重试。',
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                          TextButton(
                            onPressed: _loadDetail,
                            child: const Text('重试'),
                          ),
                        ],
                      );
                    }
                    final fullEntries = _relatedDetailEntries(snapshot.data!);
                    if (fullEntries.isEmpty) {
                      return Text(
                        previewEntries.isEmpty
                            ? '该关联记录没有可展示的字段变化。'
                            : '没有更多字段详情。',
                        style: theme.textTheme.bodyMedium,
                      );
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '完整字段详情',
                          style: theme.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s4),
                        for (final fullEntry in fullEntries)
                          _AuditChangeRow(entry: fullEntry),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

List<_AuditChangeEntry> _relatedDetailEntries(AuditLogDetail detail) {
  Map<String, dynamic> decode(String? raw) {
    if (raw == null || raw.trim().isEmpty) return const {};
    try {
      final value = jsonDecode(raw);
      return value is Map<String, dynamic> ? value : const {};
    } catch (_) {
      return const {};
    }
  }

  String safeValue(dynamic value) {
    if (AuditFieldLabels.looksLikeUuid(value)) return '关联对象';
    if (value is Map || value is List) return '结构化内容';
    return AuditFieldLabels.valueOf(value);
  }

  final before = decode(detail.beforeJson);
  final after = decode(detail.afterJson);
  final keys = {...before.keys, ...after.keys}.toList()..sort();
  final snapshotEntries = keys
      .where((key) => jsonEncode(before[key]) != jsonEncode(after[key]))
      .take(20)
      .map(
        (key) => _AuditChangeEntry.ofField(
          AuditFieldLabels.labelOf(key),
          safeValue(before[key]),
          safeValue(after[key]),
        ),
      )
      .toList(growable: false);
  return snapshotEntries.isNotEmpty
      ? snapshotEntries
      : _parseChangeEntries(detail);
}

enum _RefKind {
  warehouse,
  currency,
  color,
  unit,
  goods,
  supplier,
  department,
  employee,
  unknown,
}

class _AuditDiffRow extends StatelessWidget {
  const _AuditDiffRow({required this.field, this.before, this.after});

  /// 已中文化的字段标签
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
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: SelectableText(
                  field,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
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
        _LocalReceiptAuthorizationCard(
          eventId: eventId,
          state: _authorization,
          onAuthorize: _authorizeLocalReceiptRead,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _ServerDeviceCard(detail: widget.detail),
        const SizedBox(height: UtenSpacing.s12),
        _CorrelationCard(detail: widget.detail, receipt: null),
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
        '时区偏移(分钟)',
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
            title: Text('请求尝试链(${receipt.allAttempts.length} 次)'),
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
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  '以下内容仅用于技术排查。普通核查请优先阅读概览、业务变化和设备证据。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          padding: EdgeInsets.zero,
          child: ExpansionTile(
            key: const ValueKey('audit-technical-expansion'),
            title: const Text('展开技术排查数据'),
            subtitle: const Text('包含操作关联编号、请求路径、原始编码和客户端标识'),
            children: [
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: UtenSpacing.s24,
                      runSpacing: UtenSpacing.s16,
                      children: [
                        _AuditFact(label: '原始动作编码', value: detail.action),
                        _AuditFact(
                          label: '原始对象编码',
                          value: detail.targetType ?? '—',
                        ),
                        _AuditFact(
                          label: '记录来源',
                          value: _sourceLabel(detail.eventSource),
                        ),
                        _CopyableAuditFact(
                          label: '操作关联编号',
                          value: detail.requestId ?? '—',
                        ),
                        _AuditFact(label: '网络来源地址', value: detail.ip ?? '—'),
                        _AuditFact(
                          label: '请求方法',
                          value: detail.httpMethod ?? '—',
                        ),
                        _AuditFact(
                          label: '请求状态码',
                          value: detail.statusCode?.toString() ?? '—',
                        ),
                        _AuditFact(
                          label: '处理耗时',
                          value: detail.durationMs == null
                              ? '—'
                              : '${detail.durationMs} 毫秒',
                        ),
                        if (detail.targetId?.trim().isNotEmpty == true)
                          _CopyableAuditFact(
                            label: '业务对象内部编号',
                            value: detail.targetId!,
                          ),
                      ],
                    ),
                    if (detail.httpPath?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      _AuditFact(label: '请求路径', value: detail.httpPath!),
                    ],
                    if (detail.userAgent?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      _AuditFact(label: '客户端标识', value: detail.userAgent!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
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
