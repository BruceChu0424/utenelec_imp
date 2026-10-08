// AdminAiUsageRecordsPage - AI 使用记录与费用(自 AI 服务设置页的内嵌面板升级为独立页面)。
//
// 结构: 顶部汇总卡(使用条数/实际费用/估算费用/费用待确认) → 筛选工具条(按记录|按人员
// 视图切换 + 时间/使用人/AI 服务下拉) → 表格(按记录=逐条明细、按人员=每人一行汇总,
// 行尾「查看记录」跳回按记录视图并锁定该人)。计费方式与套餐额度在右上「计费设置」
// 抽屉里维护, 不再和查询混在一起。
//
// 安全:
//   * 路由 /admin/* 要求 authorization:manage; 服务端 Controller 另校验 superAdmin;
//     页内再叠超管门禁(会话/快照/服务器/权限任一变化即失效, 与用量看板同款)。
//   * 读端点不写数据; 保存计费走抽屉(服务端要求再认证, 网络层弹统一密码框)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/ai_provider_models.dart';
import '../models/ai_usage_audit_models.dart';
import '../repositories/ai_provider_repository.dart';
import '../repositories/ai_usage_audit_repository.dart';
import '../widgets/ai_billing_editor.dart';
import '../widgets/ai_usage_trend_card.dart' show formatAiUsageNumber;

Object? _recordsOwner(WidgetRef ref, {bool watch = false}) {
  final scope = watch
      ? ref.watch(authenticatedScopeProvider)
      : ref.read(authenticatedScopeProvider);
  final session = watch
      ? ref.watch(sessionProvider)
      : ref.read(sessionProvider);
  final snapshot = confirmedSessionSnapshot(
    watch
        ? ref.watch(sessionSnapshotProvider)
        : ref.read(sessionSnapshotProvider),
  );
  final server = watch
      ? ref.watch(apiBaseUrlProvider)
      : ref.read(apiBaseUrlProvider);
  final permissions = watch
      ? ref.watch(currentPermissionsProvider)
      : ref.read(currentPermissionsProvider);
  if (scope == null ||
      scope.actorId != null ||
      scope.readOnly ||
      snapshot == null ||
      session.user?.id != scope.userId ||
      session.user?.superAdmin != true ||
      !permissions.contains(Perm.authorizationManage)) {
    return null;
  }
  return (scope, snapshot.generation, server);
}

enum _RecordsView { records, people }

class AdminAiUsageRecordsPage extends ConsumerWidget {
  const AdminAiUsageRecordsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = _recordsOwner(ref, watch: true);
    if (owner == null) {
      final l10n = AppLocalizations.of(context);
      return Scaffold(
        appBar: UtenAppBar(
          title: l10n.aiAuditTitle,
          leading: const UtenBackButton(),
        ),
        body: UtenEmpty.error(
          key: const ValueKey('ai-records-error'),
          message: l10n.aiSettingsNoAccess,
        ),
      );
    }
    return _AdminAiUsageRecordsSession(key: ValueKey(owner));
  }
}

class _AdminAiUsageRecordsSession extends ConsumerStatefulWidget {
  const _AdminAiUsageRecordsSession({super.key});

  @override
  ConsumerState<_AdminAiUsageRecordsSession> createState() =>
      _AdminAiUsageRecordsPageState();
}

class _AdminAiUsageRecordsPageState
    extends ConsumerState<_AdminAiUsageRecordsSession> {
  late final Object? _owner;
  bool get _current =>
      mounted && _owner != null && _owner == _recordsOwner(ref);

  static const _pageSize = 20;
  static const _dayChoices = [7, 30, 90, 180];

  _RecordsView _view = _RecordsView.records;
  int _days = 30;
  String? _userId;
  String? _providerId;
  int _page = 0;

  AiUsageAuditResult? _data;

  /// 最近一次「全部员工」查询返回的人员汇总(筛选某个人后服务端不再下发, 保留旧值供下拉)。
  List<AiUsageAuditUser> _users = [];
  List<AiProviderConfig> _providers = const [];
  bool _loading = false;
  bool _accessDenied = false;
  String? _error;
  int _generation = 0;

  AiUsageAuditRepository get _repository =>
      ref.read(aiUsageAuditRepositoryProvider);
  AiProviderRepository get _providerRepository =>
      ref.read(aiProviderRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = _recordsOwner(ref);
    _loadProviders();
    _load();
  }

  Future<void> _loadProviders() async {
    if (!_current) return;
    try {
      final providers = await _providerRepository.list();
      if (!_current) return;
      setState(() => _providers = providers);
    } catch (_) {
      // 服务商读失败不打断记录查询: 筛选下拉只缺可选项, 手动刷新会重试。
    }
  }

  Future<void> _load({bool resetPage = false}) async {
    if (!_current) return;
    final generation = ++_generation;
    if (resetPage) _page = 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await _repository.read(
        days: _days,
        page: _page,
        userId: _userId,
        providerId: _providerId,
      );
      if (!_current || generation != _generation) return;
      final typed = AiUsageAuditResult.fromJson(result);
      setState(() {
        _data = typed;
        if (_userId == null) _users = typed.users;
        _loading = false;
        _accessDenied = false;
        _error = null;
      });
    } catch (error) {
      if (!_current || generation != _generation) return;
      if (_isAccessDenied(error)) {
        _deny(error as ApiException);
        return;
      }
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : AppLocalizations.of(context).aiAuditLoadFailed;
      });
    }
  }

  Future<void> _refresh() async {
    if (_loading) return;
    await _loadProviders();
    await _load();
  }

  void _deny(ApiException error) {
    _generation++;
    setState(() {
      _loading = false;
      _accessDenied = true;
      _data = null;
      _users = [];
      _userId = null;
      _providerId = null;
      _error = error.message;
    });
  }

  // ---- 筛选动作 ----

  void _changeDays(int days) {
    if (days == _days) return;
    _days = days;
    _load(resetPage: true);
  }

  void _changeUser(String? userId) {
    final next = userId;
    if (next == _userId) return;
    _userId = next;
    // 锁定某人后「按人员」视图没有意义, 回到按记录。
    if (next != null && _view == _RecordsView.people) {
      _view = _RecordsView.records;
    }
    _load(resetPage: true);
  }

  void _changeProvider(String? providerId) {
    if (providerId == _providerId) return;
    _providerId = providerId;
    _load(resetPage: true);
  }

  void _changeView(_RecordsView view) {
    if (view == _view) return;
    setState(() => _view = view);
    // 进入「按人员」需要全员汇总, 先解除单人锁定。
    if (view == _RecordsView.people && _userId != null) {
      _userId = null;
      _load(resetPage: true);
    }
  }

  Future<void> _openBilling() async {
    if (_providers.isEmpty) return;
    final saved = await showAiBillingEditor(
      context,
      providers: _providers,
      onDenied: (error) {
        if (_current) _deny(error);
      },
    );
    if (!mounted || !_current) return;
    if (saved) await _load();
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final Widget body;
    if (_accessDenied) {
      body = UtenEmpty.error(
        key: const ValueKey('ai-records-denied'),
        message: _error ?? l10n.aiAuditLoadFailed,
        actionLabel: l10n.aiSettingsRetry,
        onAction: _load,
      );
    } else if (_loading && _data == null) {
      body = const _LoadingSkeleton();
    } else if (_error != null && _data == null) {
      body = UtenEmpty.error(
        key: const ValueKey('ai-records-error'),
        message: _error!,
        actionLabel: l10n.aiSettingsRetry,
        onAction: _load,
      );
    } else {
      body = RefreshIndicator(onRefresh: _refresh, child: _content(l10n));
    }
    return Scaffold(
      appBar: UtenAppBar(
        title: l10n.aiAuditTitle,
        leading: const UtenBackButton(),
        actions: [
          UtenButton(
            key: const ValueKey('ai-records-billing-open'),
            type: UtenButtonType.ghost,
            icon: Icons.receipt_long_outlined,
            onPressed: _providers.isEmpty ? null : _openBilling,
            child: Text(l10n.aiRecordsBillingOpen),
          ),
          const SizedBox(width: UtenSpacing.s4),
          IconButton(
            key: const ValueKey('ai-records-refresh'),
            tooltip: l10n.aiAuditRefresh,
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
      body: UtenContentContainer(child: body),
    );
  }

  Widget _content(AppLocalizations l10n) {
    final data = _data;
    return ListView(
      key: const ValueKey('ai-records-list'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      children: [
        _SummaryRow(key: const ValueKey('ai-records-summary'), data: data),
        const SizedBox(height: UtenSpacing.s8),
        _PlatformNote(text: l10n.aiAuditPlatformOnly),
        const SizedBox(height: UtenSpacing.s16),
        _toolbar(l10n),
        const SizedBox(height: UtenSpacing.s12),
        if (_view == _RecordsView.records)
          _recordsCard(l10n, data)
        else
          _peopleCard(l10n, data),
        const SizedBox(height: UtenSpacing.s24),
      ],
    );
  }

  Widget _toolbar(AppLocalizations l10n) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        UtenSegmentedFilter<_RecordsView>(
          key: const ValueKey('ai-records-view-filter'),
          segments: [
            UtenSegment(
              value: _RecordsView.records,
              label: l10n.aiRecordsViewRecords,
            ),
            UtenSegment(
              value: _RecordsView.people,
              label: l10n.aiRecordsViewByPerson,
            ),
          ],
          selected: _view,
          onChanged: _loading ? (value) {} : _changeView,
        ),
        SizedBox(
          width: 190,
          child: UtenDropdownField(
            key: const ValueKey('ai-records-days'),
            label: l10n.aiAuditPeriod,
            value: _days.toString(),
            allowClear: false,
            items: [
              for (final days in _dayChoices)
                UtenDropdownItem(
                  value: days.toString(),
                  label: l10n.aiAuditRecentDays(days),
                ),
            ],
            enabled: !_loading,
            onChanged: (value) {
              if (value != null) _changeDays(int.tryParse(value) ?? 30);
            },
          ),
        ),
        if (_view == _RecordsView.records) ...[
          SizedBox(
            width: 210,
            child: UtenDropdownField(
              key: const ValueKey('ai-records-user'),
              label: l10n.aiAuditUser,
              value: _userId,
              items: [
                UtenDropdownItem(label: l10n.aiAuditAllUsers),
                for (final user in _users)
                  UtenDropdownItem(
                    value: user.userId,
                    label: _personLabel(l10n, name: user.name, code: user.code),
                  ),
              ],
              enabled: !_loading,
              onChanged: _changeUser,
            ),
          ),
          SizedBox(
            width: 210,
            child: UtenDropdownField(
              key: const ValueKey('ai-records-provider'),
              label: l10n.aiAuditProvider,
              value: _providerId,
              items: [
                UtenDropdownItem(label: l10n.aiAuditAllProviders),
                for (final provider in _providers)
                  UtenDropdownItem(value: provider.id, label: provider.name),
              ],
              enabled: !_loading,
              onChanged: _changeProvider,
            ),
          ),
        ],
      ],
    );
  }

  Widget _recordsCard(AppLocalizations l10n, AiUsageAuditResult? data) {
    final totalPages = data == null
        ? 1
        : (data.total + _pageSize - 1) ~/ _pageSize;
    final page = _page.clamp(0, totalPages - 1);
    return UtenCard(
      key: const ValueKey('ai-records-card'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          MasterDataTableView<AiUsageAuditRecord>(
            tableKey:
                'features.admin.pages.admin_ai_usage_records_page.RecordsTable.build.1',
            key: const Key('ai-records-table'),
            embedded: true,
            isLoading: _loading && data == null,
            items: data?.records ?? const <AiUsageAuditRecord>[],
            columns: _recordColumns(l10n),
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (key, value) {},
            onRowTap: (record) => _showDetail(record),
            rowKeyOf: (record) => record.id,
            currentPage: page + 1,
            totalPages: totalPages,
            onPageChange: (target) {
              _page = target - 1;
              _load();
            },
            paginationScope: (_days, _userId, _providerId),
            paginationRevision: data,
            emptyMessage: l10n.aiAuditEmpty,
          ),
        ],
      ),
    );
  }

  Widget _peopleCard(AppLocalizations l10n, AiUsageAuditResult? data) {
    return UtenCard(
      key: const ValueKey('ai-records-people-card'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          MasterDataTableView<AiUsageAuditUser>(
            tableKey:
                'features.admin.pages.admin_ai_usage_records_page.PeopleTable.build.1',
            key: const Key('ai-records-people-table'),
            embedded: true,
            isLoading: _loading && data == null,
            items: _users,
            columns: _peopleColumns(l10n),
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (key, value) {},
            rowKeyOf: (user) => user.userId,
            emptyMessage: l10n.aiRecordsPersonEmpty,
          ),
        ],
      ),
    );
  }

  List<MasterColumnDef<AiUsageAuditRecord>> _recordColumns(
    AppLocalizations l10n,
  ) {
    return [
      MasterColumnDef(
        key: 'time',
        label: l10n.aiRecordsColTime,
        width: 150,
        value: (row) => _beijing(row.createdAt),
      ),
      MasterColumnDef(
        key: 'person',
        label: l10n.aiAuditUser,
        width: 170,
        value: (row) => _personLabel(l10n, name: row.name, code: row.code),
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _displayName(l10n, row.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (row.code.isNotEmpty)
                Text(
                  row.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
        },
      ),
      MasterColumnDef(
        key: 'purpose',
        label: l10n.aiRecordsColPurpose,
        width: 120,
        value: (row) => _purposeLabel(l10n, row),
      ),
      MasterColumnDef(
        key: 'question',
        label: l10n.aiRecordsColQuestion,
        width: 280,
        value: (row) => row.question,
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Text(
            row.question.isEmpty
                ? l10n.aiAuditQuestionMissing(_purposeLabel(l10n, row))
                : row.question,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium,
          );
        },
      ),
      MasterColumnDef(
        key: 'provider',
        label: l10n.aiAuditProvider,
        width: 150,
        value: (row) => row.providerNames.join(' / '),
      ),
      MasterColumnDef(
        key: 'model',
        label: l10n.aiRecordsColModel,
        width: 160,
        value: (row) => row.models.join(' / '),
      ),
      MasterColumnDef(
        key: 'calls',
        label: l10n.aiRecordsColCalls,
        width: 90,
        type: 'number',
        value: (row) => '${row.metrics.calls}',
      ),
      MasterColumnDef(
        key: 'inputTokens',
        label: l10n.aiRecordsColInputTokens,
        width: 110,
        type: 'number',
        value: (row) => _tokenText(row.inputTokens),
      ),
      MasterColumnDef(
        key: 'outputTokens',
        label: l10n.aiRecordsColOutputTokens,
        width: 110,
        type: 'number',
        value: (row) => _tokenText(row.outputTokens),
      ),
      MasterColumnDef(
        key: 'cost',
        label: l10n.aiRecordsColCost,
        width: 190,
        value: (row) => _costCellValue(l10n, row.metrics),
        cellBuilder: (context, row) => _CostCell(metrics: row.metrics),
      ),
      MasterColumnDef(
        key: 'status',
        label: l10n.aiRecordsColStatus,
        width: 96,
        value: (row) => _statusLabel(l10n, row.status),
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) => Semantics(
          excludeSemantics: true,
          label: '${l10n.aiRecordsColStatus} ${_statusLabel(l10n, row.status)}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: UtenStatusBadge(
              label: _statusLabel(l10n, row.status),
              type: _statusBadgeType(row.status),
              size: UtenStatusBadgeSize.small,
            ),
          ),
        ),
      ),
    ];
  }

  List<MasterColumnDef<AiUsageAuditUser>> _peopleColumns(
    AppLocalizations l10n,
  ) {
    return [
      MasterColumnDef(
        key: 'person',
        label: l10n.aiAuditUser,
        width: 220,
        value: (row) => _personLabel(l10n, name: row.name, code: row.code),
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _displayName(l10n, row.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (row.code.isNotEmpty)
                Text(
                  row.code,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          );
        },
      ),
      MasterColumnDef(
        key: 'uses',
        label: l10n.aiRecordsStatUses,
        width: 150,
        type: 'number',
        value: (row) => '${row.metrics.uses}',
        cellBuilder: (context, row) {
          final theme = Theme.of(context);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.aiAuditUses(row.metrics.uses),
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                l10n.aiRecordsStatCallsFooter(row.metrics.calls),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          );
        },
      ),
      MasterColumnDef(
        key: 'cost',
        label: l10n.aiRecordsColCost,
        width: 240,
        value: (row) => _costCellValue(l10n, row.metrics),
        cellBuilder: (context, row) => _CostCell(metrics: row.metrics),
      ),
      MasterColumnDef(
        key: 'actions',
        label: l10n.aiRecordsPersonViewRecords,
        width: 110,
        value: (row) => l10n.aiRecordsPersonViewRecords,
        cellBuilderHandlesSemantics: true,
        cellBuilder: (context, row) => Semantics(
          button: true,
          excludeSemantics: true,
          label:
              '${l10n.aiRecordsPersonViewRecords} ${_displayName(l10n, row.name)}',
          child: Align(
            alignment: Alignment.centerLeft,
            child: IconButton(
              key: ValueKey('ai-records-person-view-${row.userId}'),
              tooltip: l10n.aiRecordsPersonViewRecords,
              icon: const Icon(Icons.list_alt_outlined, size: 20),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              onPressed: () {
                setState(() => _view = _RecordsView.records);
                _changeUser(row.userId);
              },
            ),
          ),
        ),
      ),
    ];
  }

  Future<void> _showDetail(AiUsageAuditRecord record) async {
    await showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 480,
      builder: (_) => _RecordDetailPanel(record: record),
    );
  }
}

// ---- 汇总卡 ----

/// 四张等高汇总卡: 使用条数 / 实际费用 / 估算费用 / 费用待确认。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({super.key, required this.data});

  final AiUsageAuditResult? data;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final metrics = data?.summary;
    final actual = metrics?.costOf(true);
    final estimated = metrics?.costOf(false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 640 ? 4 : 2;
        const gap = UtenSpacing.s8;
        final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
        Widget card({
          Key? key,
          required IconData icon,
          required String label,
          required String value,
          required String footer,
          bool warning = false,
        }) {
          return SizedBox(
            width: width,
            child: _SummaryCard(
              key: key,
              icon: icon,
              label: label,
              value: value,
              footer: footer,
              warning: warning,
            ),
          );
        }

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            card(
              key: const ValueKey('ai-records-stat-uses'),
              icon: Icons.manage_search_outlined,
              label: l10n.aiRecordsStatUses,
              value: metrics == null ? '—' : formatAiUsageNumber(metrics.uses),
              footer: metrics == null
                  ? '—'
                  : l10n.aiRecordsStatCallsFooter(metrics.calls),
            ),
            card(
              key: const ValueKey('ai-records-stat-actual'),
              icon: Icons.payments_outlined,
              label: l10n.aiRecordsStatCostActual,
              value: _costAmount(l10n, actual),
              footer: l10n.aiRecordsStatCostActualFooter,
            ),
            card(
              key: const ValueKey('ai-records-stat-estimated'),
              icon: Icons.calculate_outlined,
              label: l10n.aiRecordsStatCostEstimated,
              value: _costAmount(l10n, estimated),
              footer: l10n.aiRecordsStatCostEstimatedFooter,
            ),
            card(
              key: const ValueKey('ai-records-stat-unknown'),
              icon: Icons.help_outline_rounded,
              label: l10n.aiRecordsStatUnknown,
              value: metrics == null || metrics.unknownCostCalls == 0
                  ? '—'
                  : formatAiUsageNumber(metrics.unknownCostCalls),
              footer: metrics == null || metrics.unknownCostCalls == 0
                  ? l10n.aiAuditLocalOnly
                  : l10n.aiRecordsStatUnknownFooter(metrics.unknownCostCalls),
              warning: (metrics?.unknownCostCalls ?? 0) > 0,
            ),
          ],
        );
      },
    );
  }

  static String _costAmount(AppLocalizations l10n, AiUsageAuditCost? cost) {
    if (cost == null) return '—';
    if (cost.pending) return l10n.aiAuditCostPending;
    return '${cost.currency} ${cost.amount}';
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.footer,
    this.warning = false,
  });

  final IconData icon;
  final String label;
  final String value;
  final String footer;
  final bool warning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = warning ? theme.colorScheme.error : theme.colorScheme.primary;
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 108),
      child: UtenCard(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.12),
                    borderRadius: UtenRadius.mdAll,
                  ),
                  child: Icon(icon, size: 18, color: color),
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w800,
                color: warning ? color : null,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: UtenSpacing.s2),
            Text(
              footer,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PlatformNote extends StatelessWidget {
  const _PlatformNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.info_outline_rounded,
          size: 14,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// 费用列单元格: 实际/估算各一行(有才显示), 都没有时按调用量给占位。
class _CostCell extends StatelessWidget {
  const _CostCell({required this.metrics});

  final AiUsageAuditMetrics metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    if (metrics.costs.isEmpty) {
      return Text(
        metrics.calls == 0 ? l10n.aiAuditLocalOnly : l10n.aiAuditCostPending,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final cost in metrics.costs)
          Text(
            cost.actual
                ? l10n.aiAuditActualCost(
                    cost.currency,
                    cost.pending ? l10n.aiAuditCostPending : cost.amount,
                  )
                : l10n.aiAuditEstimatedCost(
                    cost.currency,
                    cost.pending ? l10n.aiAuditCostPending : cost.amount,
                  ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );
  }
}

/// 单条使用详情右侧抽屉: 问题全文 + 用途/服务/模型/token/费用。
class _RecordDetailPanel extends StatelessWidget {
  const _RecordDetailPanel({required this.record});

  final AiUsageAuditRecord record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final purpose = _purposeLabel(l10n, record);
    return SingleChildScrollView(
      key: const ValueKey('ai-records-detail'),
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.manage_search_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  l10n.aiRecordsDetailTitle,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Wrap(
            spacing: UtenSpacing.s6,
            runSpacing: UtenSpacing.s4,
            children: [
              UtenStatusBadge(
                label: _statusLabel(l10n, record.status),
                type: _statusBadgeType(record.status),
                size: UtenStatusBadgeSize.small,
              ),
              UtenStatusBadge(
                label: purpose,
                type: UtenStatusBadgeType.neutral,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          SelectableText(
            record.question.isEmpty
                ? l10n.aiAuditQuestionMissing(_kindLabel(l10n, record))
                : record.question,
            style: theme.textTheme.titleSmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenInfoRow(
            label: l10n.aiRecordsColTime,
            value: _beijing(record.createdAt),
          ),
          UtenInfoRow(
            label: l10n.aiAuditUser,
            value: _personLabel(l10n, name: record.name, code: record.code),
          ),
          UtenInfoRow(
            label: l10n.aiRecordsColPurpose,
            value: record.intent == 'NON_WORK'
                ? '$purpose (${l10n.aiAuditNonWorkRefused})'
                : purpose,
          ),
          if (record.providerNames.isNotEmpty)
            UtenInfoRow(
              label: l10n.aiAuditProvider,
              value: record.providerNames.join(' / '),
            ),
          if (record.models.isNotEmpty)
            UtenInfoRow(
              label: l10n.aiRecordsColModel,
              value: record.models.join(' / '),
            ),
          UtenInfoRow(
            label: l10n.aiRecordsColCalls,
            value: l10n.aiAuditTokens(
              record.metrics.calls,
              _tokenText(record.inputTokens),
              _tokenText(record.outputTokens),
            ),
            showDivider: false,
          ),
        ],
      ),
    );
  }
}

/// 首次加载的骨架: 汇总行 + 工具条 + 表格的轮廓。
class _LoadingSkeleton extends StatelessWidget {
  const _LoadingSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('ai-records-skeleton'),
      padding: const EdgeInsets.all(UtenSpacing.s16),
      physics: const NeverScrollableScrollPhysics(),
      children: const [
        Row(
          children: [
            Expanded(child: UtenSkeleton(height: 108, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 108, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 108, borderRadius: 14)),
            SizedBox(width: UtenSpacing.s8),
            Expanded(child: UtenSkeleton(height: 108, borderRadius: 14)),
          ],
        ),
        SizedBox(height: UtenSpacing.s16),
        UtenSkeleton(height: 44, borderRadius: 10),
        SizedBox(height: UtenSpacing.s12),
        UtenSkeleton(height: 280, borderRadius: 14),
      ],
    );
  }
}

// ---- 共用文案/格式 ----

String _beijing(String iso) =>
    iso.isEmpty ? '—' : DisplayDateTime.beijing(iso, fallback: '—');

String _tokenText(int? value) =>
    value == null ? '—' : formatAiUsageNumber(value);

String _displayName(AppLocalizations l10n, String name) =>
    name.isEmpty ? l10n.aiAuditPersonUnknown : name;

String _personLabel(
  AppLocalizations l10n, {
  required String name,
  required String code,
}) => code.isEmpty
    ? _displayName(l10n, name)
    : '${_displayName(l10n, name)}（$code）';

String _statusLabel(AppLocalizations l10n, String status) => switch (status) {
  'SUCCEEDED' => l10n.aiAuditSucceeded,
  'FAILED' => l10n.aiAuditFailed,
  'CANCELLED' => l10n.aiAuditCancelled,
  'QUEUED' || 'PENDING' => l10n.aiAuditQueued,
  'RUNNING' => l10n.aiAuditRunning,
  _ => status.isEmpty ? '—' : status,
};

UtenStatusBadgeType _statusBadgeType(String status) => switch (status) {
  'SUCCEEDED' => UtenStatusBadgeType.success,
  'FAILED' => UtenStatusBadgeType.danger,
  'RUNNING' => UtenStatusBadgeType.warning,
  _ => UtenStatusBadgeType.neutral,
};

String _kindLabel(AppLocalizations l10n, AiUsageAuditRecord row) =>
    switch (row.kind) {
      'ERP_CHAT' => l10n.aiAuditKindChat,
      'ERP_DOCUMENT_ROUTE' => l10n.aiAuditKindDocument,
      'SALES_DOCUMENT_INTAKE' => l10n.aiAuditKindSales,
      _ => l10n.aiAuditKindOther,
    };

String _purposeLabel(AppLocalizations l10n, AiUsageAuditRecord row) {
  final kind = _kindLabel(l10n, row);
  return switch (row.intent) {
    'query_goods_cost' => l10n.aiAuditPurposeCost,
    'inventory_lookup' => l10n.aiAuditPurposeStock,
    'query_client_credit' => l10n.aiAuditPurposeCredit,
    'SALES_ORDER' => l10n.aiAuditPurposeOrder,
    'SALES_QUOTE' => l10n.aiAuditPurposeQuote,
    'EXPENSE_CLAIM' => l10n.aiAuditPurposeExpense,
    'production_in_progress' => l10n.aiAuditPurposeProduction,
    'workbench_tasks' => l10n.aiAuditPurposeWorkbench,
    'feature_directory' => l10n.aiAuditPurposeDirectory,
    'my_access' => l10n.aiAuditPurposeAccess,
    'sales_order_progress' => l10n.aiAuditPurposeSalesOrder,
    'purchase_order_status' => l10n.aiAuditPurposePurchaseOrder,
    'subcontract_order_status' => l10n.aiAuditPurposeSubcontract,
    'PAGE_HELP' => l10n.aiAuditPurposePageHelp,
    'PAGE_STATE' => l10n.aiAuditPurposePageState,
    'ACTION' => l10n.aiAuditPurposeAction,
    'prepare_permission_grant' => l10n.aiAuditPurposeGrant,
    _ => kind,
  };
}

String _costCellValue(AppLocalizations l10n, AiUsageAuditMetrics metrics) {
  if (metrics.costs.isEmpty) {
    return metrics.calls == 0 ? l10n.aiAuditLocalOnly : l10n.aiAuditCostPending;
  }
  return metrics.costs
      .map(
        (cost) => cost.actual
            ? l10n.aiAuditActualCost(
                cost.currency,
                cost.pending ? l10n.aiAuditCostPending : cost.amount,
              )
            : l10n.aiAuditEstimatedCost(
                cost.currency,
                cost.pending ? l10n.aiAuditCostPending : cost.amount,
              ),
      )
      .join('；');
}

bool _isAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        error.code == 'FORBIDDEN' ||
        error.code == 'UNAUTHENTICATED');
