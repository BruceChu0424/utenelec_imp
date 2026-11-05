import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_close_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/finance_requirement_names.dart';
import '../config/finance_application_routes.dart';
import '../widgets/finance_application_detail.dart';

const financeApplicationsApi = '/finance/applications';
List<Map<String, dynamic>> financeApplicationRows(Object? value) =>
    value is List
    ? [
        for (final row in value)
          if (row is Map) Map<String, dynamic>.from(row),
      ]
    : [];
Map<String, dynamic> financeApplicationMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
String financeApplicationStatus(Object? value) =>
    const {
      'DRAFT': '草稿',
      'SUBMITTED': '已提交',
      'REVIEWING': '审核中',
      'APPROVED': '已批准支付',
      'ARCHIVED': '财务已保管',
      'REJECTED': '已退回',
      'EXECUTED': '已执行待财务确认',
      'CONFIRMED': '财务已确认',
      'REVERSED': '已撤销执行',
      'PENDING': '待办理',
      'WITHDRAWN': '已撤回',
    }[value] ??
    value?.toString() ??
    '';
MasterColumnDef<Map<String, dynamic>> financeApplicationColumn(
  String key,
  String label,
  double width, {
  bool filters = true,
}) => MasterColumnDef(
  key: key,
  label: label,
  width: width,
  value: (r) => r[key]?.toString() ?? '',
  filterFromRows: filters,
  columnSearchEnabled: filters,
);

/// One existing Uten table shell for the six original application paths.
class FinanceApplicationsPage extends ConsumerStatefulWidget {
  const FinanceApplicationsPage({
    super.key,
    this.applicationId,
    this.draftAction,
    this.resumeDraftId,
    this.invoiceId,
  });
  final String? applicationId, draftAction, resumeDraftId, invoiceId;
  @override
  ConsumerState<FinanceApplicationsPage> createState() =>
      _FinanceApplicationsState();
}

class _FinanceApplicationsState extends ConsumerState<FinanceApplicationsPage> {
  final _reads = LatestRequestGuard();
  Map<String, dynamic> _catalog = {};
  List<Map<String, dynamic>> _rows = [];
  String _queue = 'mine', _search = '';
  String? _error;
  bool _loading = true;
  int _page = 1, _total = 0, _epoch = -1;
  @override
  void initState() {
    super.initState();
    if (widget.applicationId == null) unawaited(_load());
  }

  Future<void> _load() async {
    final token = _reads.begin();
    final epoch = ref.read(exportContextEpochProvider);
    final api = ref.read(apiClientProvider);
    setState(() {
      _loading = true;
      _error = null;
      _epoch = epoch;
      _rows = [];
    });
    try {
      final result = await Future.wait([
        api.get('$financeApplicationsApi/catalog'),
        api.get(
          financeApplicationsApi,
          query: {
            'queue': _queue,
            'search': _search,
            'page': _page,
            'size': 30,
          },
        ),
      ]);
      if (!mounted ||
          !_reads.isCurrent(token) ||
          epoch != ref.read(exportContextEpochProvider)) {
        return;
      }
      setState(() {
        _catalog = result[0];
        _rows = financeApplicationRows(result[1]['rows']);
        _total = (result[1]['total'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (mounted &&
          _reads.isCurrent(token) &&
          epoch == ref.read(exportContextEpochProvider)) {
        setState(() {
          _error = humanErrorMessage(e) ?? '申请读取未完成';
          _loading = false;
        });
      }
    }
  }

  Future<void> _new() async {
    final openingEpoch = ref.read(exportContextEpochProvider);
    final types = financeApplicationRows(_catalog['types']);
    final permissions = ref.read(currentPermissionsProvider);
    final available = types.where((type) {
      final kind = type['key']?.toString() ?? '';
      return financeApplicationCreateLocation(kind) != null &&
          (type.containsKey('canApply')
              ? type['canApply'] == true
              : canCreateFinanceApplicationKind(kind, permissions));
    }).toList();
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => UtenAlertDialog(
        title: const Text('选择申请类型'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final t in available)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: () => Navigator.pop(ctx, t['key'].toString()),
                    child: Text(t['label'].toString()),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    if (selected != null &&
        mounted &&
        openingEpoch == ref.read(exportContextEpochProvider)) {
      final location = financeApplicationCreateLocation(selected);
      if (location != null) context.push(location);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(apiClientProvider);
    final epoch = ref.watch(exportContextEpochProvider);
    final perms = ref.watch(currentPermissionsProvider);
    if (widget.applicationId != null) {
      return FinanceApplicationDetail(
        applicationId: widget.applicationId!,
        draftAction: widget.draftAction,
        resumeDraftId: widget.resumeDraftId,
        invoiceId: widget.invoiceId,
      );
    }
    final current = epoch == _epoch;
    final actionable = perms.contains(Perm.financeApplicationReview);
    return Scaffold(
      appBar: UtenAppBar(
        title: FinanceRequirementNames.financeApplications,
        showBackButton: true,
        actions: [
          if (perms.contains(Perm.expenseSettings))
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => context.push('/finance/applications/settings'),
              child: const Text('流程设置'),
            ),
          // 2026-11-04 刷新按钮归位：不再放分类栏行尾，与其他任务中心同位
          // 右上角 AppBar（UtenRefreshButton 自带 busy 转圈与防重入）。
          UtenRefreshButton(busy: _loading, onRefresh: _load),
        ],
      ),
      body: UtenContentContainer(
        // 2026-11-04 上滑先把表格钉顶（同任务中心范式）：分类行与身份提示进
        // 折叠头随页滚走，表格工具条+表头钉在页面顶部。
        child: UtenCollapsingHeaderScrollView(
          collapsingHeader: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: UtenFilterToolbar<String>(
                  segments: [
                    const UtenFilterSegment(value: 'mine', label: '本人申请'),
                    if (actionable)
                      const UtenFilterSegment(value: 'pending', label: '指派待办'),
                    if (perms.contains(Perm.financeApplicationExecute) ||
                        perms.contains(Perm.financeApplicationConfirm) ||
                        perms.contains(Perm.financeApplicationReverse))
                      const UtenFilterSegment(value: 'payment', label: '批准及付款'),
                    const UtenFilterSegment(value: 'history', label: '申请历史'),
                  ],
                  selected: {_queue},
                  autoSelectBadge: false,
                  onSelectionChanged: (v) {
                    _queue = v;
                    _page = 1;
                    unawaited(_load());
                  },
                  searchHint: '申请单号、事由、申请人',
                  onSearchChanged: (v) {
                    _search = v;
                    _page = 1;
                    unawaited(_load());
                  },
                  trailing:
                      (perms.contains(Perm.financeApplicationApply) ||
                          perms.contains(Perm.expenseApply) ||
                          perms.contains(Perm.payrollGenerate))
                      ? UtenButton(
                          onPressed: current && !_loading ? _new : null,
                          child: const Text('新增'),
                        )
                      : null,
                ),
              ),
              if (!current) const Text('登录身份或权限已变化，请刷新当前申请范围。'),
            ],
          ),
          body: MasterDataTableView<Map<String, dynamic>>(
            columns: [
              financeApplicationColumn(
                'application_no',
                '申请单号',
                170,
                filters: false,
              ),
              financeApplicationColumn(
                'kindLabel',
                '申请类型',
                165,
                filters: false,
              ),
              financeApplicationColumn(
                'applicant_name_snapshot',
                '申请人',
                130,
                filters: false,
              ),
              financeApplicationColumn(
                'department_name_snapshot',
                '部门',
                150,
                filters: false,
              ),
              financeApplicationColumn('title', '申请事由', 250, filters: false),
              financeApplicationColumn(
                'requested_date',
                '申请日期',
                130,
                filters: false,
              ),
              financeApplicationColumn(
                'amount_original',
                '原币金额',
                160,
                filters: false,
              ),
              MasterColumnDef(
                key: 'status',
                label: '状态',
                width: 165,
                value: (r) => financeApplicationStatus(r['status']),
                columnSearchEnabled: false,
              ),
              financeApplicationColumn(
                'current_label',
                '当前步骤',
                200,
                filters: false,
              ),
            ],
            items: current ? _rows : [],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            isLoading: _loading,
            error: _error,
            onRetry: _load,
            currentPage: _page,
            totalPages: (_total / 30).ceil().clamp(1, 1 << 30),
            onPageChange: (p) {
              _page = p;
              unawaited(_load());
            },
            onRowTap: (r) {
              if (_epoch == ref.read(exportContextEpochProvider)) {
                context.push('/finance/applications/${r['id']}');
              }
            },
            rowKeyOf: (r) => r['id'].toString(),
            headerFilterScopeDescription: '搜索及分页由服务端按当前参与范围查询；行内查看原申请和节点历史',
            summaryBar: Text('共 $_total 张申请'),
            emptyMessage: '当前分类没有申请',
            primary: true,
          ),
        ),
      ),
    );
  }
}

Future<Map<String, dynamic>?> pickFinanceApplicationSource(
  BuildContext context, {
  required String kind,
  String? supplierId,
  String? currencyId,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => UtenDialogFrame(
    child: SizedBox(
      width: 820,
      height: MediaQuery.sizeOf(context).height * .78,
      child: _ApplicationSourcePicker(
        kind: kind,
        supplierId: supplierId,
        currencyId: currencyId,
      ),
    ),
  ),
);

class _ApplicationSourcePicker extends ConsumerStatefulWidget {
  const _ApplicationSourcePicker({
    required this.kind,
    this.supplierId,
    this.currencyId,
  });
  final String kind;
  final String? supplierId, currencyId;
  @override
  ConsumerState<_ApplicationSourcePicker> createState() =>
      _ApplicationSourcePickerState();
}

class _ApplicationSourcePickerState
    extends ConsumerState<_ApplicationSourcePicker> {
  final _reads = LatestRequestGuard();
  List<Map<String, dynamic>> _rows = [];
  String? _error;
  String _search = '';
  bool _loading = true, _more = false;
  int _epoch = -1;
  bool _retired = false;
  ProviderSubscription<int>? _boundary;
  @override
  void initState() {
    super.initState();
    _boundary = ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (previous == null || previous == next || !mounted) return;
      _reads.begin();
      setState(() {
        _retired = true;
        _rows = [];
        _loading = false;
        _error = '身份、授权或服务器已变化，请关闭后重新打开来源';
      });
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _boundary?.close();
    _reads.begin();
    super.dispose();
  }

  Future<void> _load() async {
    if (_retired) return;
    final token = _reads.begin(), epoch = ref.read(exportContextEpochProvider);
    setState(() {
      _epoch = epoch;
      _loading = true;
      _rows = [];
    });
    try {
      final result = await ref
          .read(apiClientProvider)
          .get(
            '$financeApplicationsApi/sources',
            query: {
              'kind': widget.kind,
              'search': _search,
              'supplierId': ?widget.supplierId,
              'currencyId': ?widget.currencyId,
            },
          );
      if (mounted &&
          _reads.isCurrent(token) &&
          epoch == ref.read(exportContextEpochProvider)) {
        setState(() {
          _rows = financeApplicationRows(result['items']);
          _more = result['more'] == true;
          _error = null;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted &&
          _reads.isCurrent(token) &&
          epoch == ref.read(exportContextEpochProvider)) {
        setState(() {
          _error = humanErrorMessage(e) ?? '原始来源未读完';
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == _epoch;
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(child: Text('选择原始来源')),
                  if (_more)
                    const UtenFieldHintIcon(info: '结果超过100条，请填写单号或名称缩小范围。'),
                  UtenCloseButton(onPressed: () => Navigator.pop(context)),
                ],
              ),
              const SizedBox(height: 12),
              UtenFilterToolbar<String>(
                searchHint: '单号、名称',
                onSearchChanged: (v) {
                  _search = v;
                  unawaited(_load());
                },
                trailing: UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _loading || _retired ? null : _load,
                  child: const Text('刷新'),
                ),
              ),
              Expanded(
                child: MasterDataTableView<Map<String, dynamic>>(
                  columns: [
                    financeApplicationColumn('code', '编号', 190, filters: false),
                    financeApplicationColumn('name', '名称', 300, filters: false),
                    financeApplicationColumn(
                      'amount',
                      '原币金额',
                      160,
                      filters: false,
                    ),
                  ],
                  items: current ? _rows : [],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  isLoading: _loading,
                  error: _error,
                  onRetry: _load,
                  onRowTap: (r) {
                    if (!_retired &&
                        _epoch == ref.read(exportContextEpochProvider)) {
                      Navigator.pop(context, r);
                    }
                  },
                  showPaginationControls: false,
                  showFullscreenToggle: false,
                  rowKeyOf: (r) =>
                      '${r['sourceKind'] ?? widget.kind}|${r['id']}',
                ),
              ),
            ],
          ),
        ),
        if (_loading)
          const UtenBusyOverlay(title: '正在读取申请来源', showDoNotLeaveHint: false),
      ],
    );
  }
}
