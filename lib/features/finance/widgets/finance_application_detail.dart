import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/concurrency/task_claim_session.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/repositories/task_claim_repository.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../expense/models/expense_claim.dart';
import '../../expense/models/expense_item.dart';
import '../../expense/widgets/expense_invoice_section.dart';
import '../config/finance_requirement_names.dart';
import '../pages/finance_applications_page.dart';
import 'finance_payroll_preparation.dart';

Object? _json(Object? value) {
  if (value is String) {
    try {
      return jsonDecode(value);
    } catch (_) {
      return null;
    }
  }
  return value;
}

const _labels = {
  'submit': '提交申请',
  'withdraw': '撤回申请',
  'approve': '通过当前步骤',
  'reject': '退回申请',
  'execute': '登记实际付款',
  'confirm': '财务确认',
  'unconfirm': '撤销财务确认',
  'reverse': '反审付款',
  'assign': '改派当前节点',
  'invoice-verification': '核验原报销票据',
  'payroll-preparation': '核对工资会计准备',
};
String financeApplicationExecutionLabel(Map<String, dynamic> row) {
  final result = financeApplicationMap(_json(row['result']));
  return switch (result['receiptKind']) {
    'NON_CASH_CLEARED' =>
      result['sourceClaimOnly'] == true ? '非现金办理认领（原凭证保留）' : '实际非现金清偿',
    'NO_FINANCIAL_EVENT' => '已核对无资金事件',
    'BANK_PAYMENT' => '工资实际付款',
    _ => switch (row['doc_type']) {
      'EXPENSE' => '原费用/报销付款',
      'PAYMENT' => '原供应商付款',
      'PAYROLL_PAYMENT' => '原工资执行',
      _ => row['doc_type']?.toString() ?? '',
    },
  };
}

String financeApplicationActionLabel(
  String mode,
  Map<String, dynamic> application,
) {
  if (mode == 'execute' &&
      application['source_kind'] == 'PAYROLL_BATCH' &&
      RegExp(
        r'^0(?:\.0+)?$',
      ).hasMatch(application['amount_original']?.toString() ?? '')) {
    return '办理工资清偿/核对';
  }
  if (mode == 'reverse') {
    final live = financeApplicationRows(
      application['executions'],
    ).where((row) => row['state'] != 'REVERSED').lastOrNull;
    final result = financeApplicationMap(_json(live?['result']));
    if (result['sourceClaimOnly'] == true) {
      return '撤销本次原凭证认领';
    }
    if (result['receiptKind'] == 'NON_CASH_CLEARED') {
      return '反审非现金清偿';
    }
    if (result['receiptKind'] == 'NO_FINANCIAL_EVENT') {
      return '撤销本次无资金核对';
    }
  }
  return _labels[mode] ?? '保存';
}

class FinanceApplicationDetail extends ConsumerStatefulWidget {
  const FinanceApplicationDetail({
    super.key,
    required this.applicationId,
    this.draftAction,
    this.resumeDraftId,
    this.invoiceId,
  });
  final String applicationId;
  final String? draftAction, resumeDraftId, invoiceId;
  @override
  ConsumerState<FinanceApplicationDetail> createState() => _DetailState();
}

class _DetailState extends ConsumerState<FinanceApplicationDetail> {
  Map<String, dynamic> _data = {};
  bool _loading = true;
  String? _error;
  int _epoch = -1, _read = 0;
  bool _resumed = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final epoch = ref.read(exportContextEpochProvider), read = ++_read;
    setState(() {
      _loading = true;
      _data = {};
      _error = null;
      _epoch = epoch;
    });
    try {
      final row = await ref
          .read(apiClientProvider)
          .get('$financeApplicationsApi/${widget.applicationId}');
      if (!mounted ||
          epoch != ref.read(exportContextEpochProvider) ||
          read != _read) {
        return;
      }
      setState(() {
        _data = row;
        _loading = false;
      });
      if (!_resumed && widget.draftAction != null) {
        _resumed = true;
        await _action(
          widget.draftAction!,
          resumeDraftId: widget.resumeDraftId,
          invoiceId: widget.invoiceId,
        );
      }
    } catch (e) {
      if (mounted &&
          epoch == ref.read(exportContextEpochProvider) &&
          read == _read) {
        setState(() {
          _error = humanErrorMessage(e) ?? '原申请未读取完成';
          _loading = false;
        });
      }
    }
  }

  Future<void> _action(
    String mode, {
    String? invoiceId,
    String? resumeDraftId,
  }) async {
    final epoch = _epoch;
    final done = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UtenDialogFrame(
        child: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .86,
          child: mode == 'payroll-preparation'
              ? FinancePayrollPreparation(
                  application: Map.unmodifiable(_data),
                  resumeDraftId: resumeDraftId,
                )
              : FinanceApplicationActionSurface(
                  application: Map.unmodifiable(_data),
                  mode: mode,
                  invoiceId: invoiceId,
                  resumeDraftId: resumeDraftId,
                ),
        ),
      ),
    );
    if (done == true &&
        mounted &&
        epoch == ref.read(exportContextEpochProvider)) {
      await _load();
    }
  }

  Widget _table(
    List<Map<String, dynamic>> rows,
    List<MasterColumnDef<Map<String, dynamic>>> cols,
  ) => MasterDataTableView<Map<String, dynamic>>(
    columns: cols,
    items: rows,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    embedded: true,
    showPaginationControls: false,
    showFullscreenToggle: false,
  );
  @override
  Widget build(BuildContext context) {
    final current = ref.watch(exportContextEpochProvider) == _epoch;
    final data = current ? _data : <String, dynamic>{};
    final actions = financeApplicationMap(data['actions']);
    final expense = financeApplicationMap(data['expenseClaim']);
    final snapshot = financeApplicationMap(data['source_snapshot']);
    final payload = financeApplicationMap(data['requested_payload']);
    final nodes = [
      for (final r in financeApplicationRows(data['nodes']))
        {
          ...r,
          'assigneesLabel': financeApplicationRows(
            _json(r['assignees']),
          ).map((a) => a['name']).join('、'),
          'stateLabel':
              const {
                'PENDING': '待办理',
                'APPROVED': '已通过',
                'ARCHIVED': '已保管',
                'REJECTED': '已退回',
                'WITHDRAWN': '已撤回',
              }[r['status']] ??
              '',
        },
    ];
    final pendingActions = [
      for (final mode in [
        'withdraw',
        'assign',
        'reject',
        'approve',
        'execute',
        'confirm',
        'unconfirm',
        'reverse',
      ])
        if (actions[mode] == true) mode,
    ];
    final isPayroll = data['source_kind'] == 'PAYROLL_BATCH';
    final zeroPayroll =
        isPayroll &&
        RegExp(
          r'^0(?:\.0+)?$',
        ).hasMatch(data['amount_original']?.toString() ?? '');
    return Scaffold(
      appBar: UtenAppBar(
        title:
            data['kindLabel']?.toString() ??
            FinanceRequirementNames.financeApplications,
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _loading ? null : _load,
            child: const Text('刷新'),
          ),
        ],
      ),
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: pendingActions.isEmpty
          ? null
          : UtenFloatingActionGroup(
              children: [
                for (final mode in pendingActions)
                  UtenButton(
                    type: mode == 'approve' || mode == 'execute'
                        ? UtenButtonType.primary
                        : UtenButtonType.secondary,
                    onPressed: () => _action(mode),
                    child: Text(financeApplicationActionLabel(mode, data)),
                  ),
              ],
            ),
      body: UtenContentContainer(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : !current
            ? const Text('身份或权限已变化，请刷新当前申请范围。')
            : _error != null
            ? Text(_error!)
            : ListView(
                padding: const EdgeInsets.only(
                  bottom: UtenFloatingActionGroup.scrollClearance,
                ),
                children: [
                  Text(
                    '${data['application_no']}　${financeApplicationStatus(data['status'])}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '申请人：${data['applicant_name_snapshot']}　部门：${data['department_name_snapshot']}',
                  ),
                  Text('申请事由：${data['title']}'),
                  Text('申请日期：${data['requested_date']}'),
                  if (data['amount_original'] != null)
                    Text('原币金额：${data['amount_original']}'),
                  if ((data['remark']?.toString() ?? '').isNotEmpty)
                    Text('备注：${data['remark']}'),
                  const SizedBox(height: 12),
                  if (actions['edit'] == true ||
                      actions['submit'] == true ||
                      actions['continue'] == true)
                    Wrap(
                      spacing: 8,
                      children: [
                        if (actions['continue'] == true)
                          UtenButton(
                            onPressed: () => context.push(
                              '/finance/applications/${data['id']}/continue?kind=${data['kind']}',
                            ),
                            child: const Text('审阅后按当前流程继续'),
                          ),
                        if (actions['edit'] == true)
                          UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: () => context.push(
                              '/finance/applications/${data['id']}/edit?kind=${data['kind']}',
                            ),
                            child: const Text('编辑申请草稿'),
                          ),
                        if (actions['submit'] == true)
                          UtenButton(
                            onPressed: () => _action('submit'),
                            child: const Text('提交申请'),
                          ),
                      ],
                    ),
                  if (payload['destination'] != null)
                    Text(
                      '出差地点：${payload['destination']}\n出差时间：${payload['travelStart']} 至 ${payload['travelEnd']}\n出差事由：${payload['travelPurpose']}',
                    ),
                  BusinessAttachmentSection(
                    ownerType: 'FINANCE_APPLICATION',
                    ownerId: widget.applicationId,
                    canView: true,
                    canManage:
                        actions['edit'] == true || actions['submit'] == true,
                    title: '申请依据',
                  ),
                  if (expense.isNotEmpty)
                    BusinessAttachmentSection(
                      ownerType: 'EXPENSE_CLAIM',
                      ownerId: data['source_id'].toString(),
                      canView: true,
                      canManage: false,
                      title: '原报销凭证',
                    ),
                  if (actions['execute'] == true && !zeroPayroll)
                    BusinessAttachmentSection(
                      ownerType: 'FINANCE_APPLICATION_PAYMENT_PROOF',
                      ownerId: widget.applicationId,
                      canView: true,
                      canManage: true,
                      title: '实际银行付款回单/现金签收凭据',
                    ),
                  if (financeApplicationRows(payload['lines']).isNotEmpty)
                    UtenCollapsibleSection(
                      title: '原申请款项',
                      child: _table(financeApplicationRows(payload['lines']), [
                        financeApplicationColumn('label', '款项说明', 300),
                        // 2026-11-11 口径：金额/日期/编号列可排序；类别列按值
                        //筛选（helper 默认已带；币种列是整单恒定值不筛）。
                        financeApplicationColumn(
                          'amountOriginal',
                          '申请原币金额',
                          190,
                          sortable: true,
                          type: 'money',
                        ),
                        financeApplicationCurrencyColumn(
                          value: (_) => financeApplicationCurrencyLabel(data),
                        ),
                      ]),
                    ),
                  UtenCollapsibleSection(
                    title: '原流程节点与签名',
                    child: _table(nodes, [
                      financeApplicationColumn(
                        'submission_round',
                        '提交轮次',
                        100,
                        sortable: true,
                      ),
                      financeApplicationColumn(
                        'step_no',
                        '步骤',
                        80,
                        sortable: true,
                      ),
                      financeApplicationColumn('label_snapshot', '原流程岗位', 250),
                      financeApplicationColumn('assigneesLabel', '明确指派人员', 260),
                      financeApplicationColumn('stateLabel', '节点状态', 130),
                      financeApplicationColumn(
                        'decided_name_snapshot',
                        '实际办理人',
                        150,
                      ),
                      financeApplicationColumn(
                        'decided_at',
                        '办理时间',
                        210,
                        sortable: true,
                      ),
                      financeApplicationColumn('reason', '处理意见', 280),
                    ]),
                  ),
                  if (expense.isNotEmpty) ...[
                    UtenCollapsibleSection(
                      title: '原报销明细',
                      child: _table(
                        [
                          for (final item in financeApplicationRows(
                            expense['items'],
                          ))
                            {
                              ...item,
                              'categoryLabel': ExpenseCategory.fromApi(
                                item['category'],
                              ).label,
                            },
                        ],
                        [
                          financeApplicationColumn(
                            'categoryLabel',
                            '报销类别',
                            140,
                          ),
                          financeApplicationColumn(
                            'date',
                            '日期',
                            130,
                            sortable: true,
                          ),
                          financeApplicationColumn('description', '说明', 300),
                          financeApplicationColumn(
                            'amountExact',
                            '金额原文',
                            160,
                            sortable: true,
                            type: 'money',
                          ),
                          financeApplicationCurrencyColumn(
                            value: (_) => expenseClaimCurrencyName,
                          ),
                        ],
                      ),
                    ),
                    ExpenseInvoiceSection(
                      claim: ExpenseClaim.fromJson(expense),
                      editable: false,
                      canVerify: actions['verifyInvoice'] == true,
                      onVerify: (invoice) => _action(
                        'invoice-verification',
                        invoiceId: invoice.id,
                      ),
                    ),
                  ],
                  if (isPayroll) ...[
                    UtenCollapsibleSection(
                      title: '原工资事实',
                      child: _table(financeApplicationRows(snapshot['slips']), [
                        // 2026-11-11 口径：编号列可排序（按值筛选 helper 默认已带）；
                        //金额列可排序；币种列是整单恒定值不筛。
                        financeApplicationColumn(
                          'employeeCode',
                          '员工编号',
                          130,
                          sortable: true,
                        ),
                        financeApplicationColumn('employeeName', '员工姓名', 160),
                        financeApplicationColumn(
                          'grossIncome',
                          '原应发工资',
                          180,
                          sortable: true,
                          type: 'money',
                        ),
                        financeApplicationColumn(
                          'totalDeduction',
                          '原扣款合计',
                          180,
                          sortable: true,
                          type: 'money',
                        ),
                        financeApplicationColumn(
                          'netIncome',
                          '原实发工资',
                          180,
                          sortable: true,
                          type: 'money',
                        ),
                        financeApplicationCurrencyColumn(
                          value: (_) => financeApplicationCurrencyLabel(data),
                        ),
                      ]),
                    ),
                    if (actions['preparePayroll'] == true)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: () => _action('payroll-preparation'),
                        child: const Text('核对工资会计准备'),
                      ),
                  ],
                  if (financeApplicationRows(data['executions']).isNotEmpty)
                    UtenCollapsibleSection(
                      title: '原执行及财务确认回执',
                      child: _table(
                        [
                          for (final r in financeApplicationRows(
                            data['executions'],
                          ))
                            {
                              ...r,
                              'executionLabel':
                                  financeApplicationExecutionLabel(r),
                              'stateLabel':
                                  const {
                                    'PREPARING': '核对中',
                                    'POSTED_PENDING_CONFIRMATION': '待财务确认',
                                    'CONFIRMED': '已财务确认',
                                    'REVERSED': '已反审',
                                  }[r['state']] ??
                                  r['state'],
                            },
                        ],
                        [
                          financeApplicationColumn(
                            'submission_round',
                            '提交轮次',
                            100,
                          ),
                          financeApplicationColumn(
                            'executionLabel',
                            '原执行类型',
                            210,
                          ),
                          financeApplicationColumn('stateLabel', '执行状态', 170),
                          financeApplicationColumn(
                            'paid_name_snapshot',
                            '实际办理人',
                            150,
                          ),
                          financeApplicationColumn('paid_at', '办理时间', 210),
                          financeApplicationColumn(
                            'confirmed_name_snapshot',
                            '财务确认人',
                            160,
                          ),
                          financeApplicationColumn(
                            'reversed_name_snapshot',
                            '反审人',
                            150,
                          ),
                        ],
                      ),
                    ),
                  UtenCollapsibleSection(
                    title: '申请历史',
                    initiallyExpanded: false,
                    child: _table(financeApplicationRows(data['events']), [
                      financeApplicationColumn('submission_round', '提交轮次', 100),
                      financeApplicationColumn('event_type', '动作', 220),
                      financeApplicationColumn(
                        'actor_name_snapshot',
                        '实际操作人',
                        150,
                      ),
                      financeApplicationColumn('occurred_at', '发生时间', 210),
                    ]),
                  ),
                ],
              ),
      ),
    );
  }
}

class FinanceApplicationActionSurface extends ConsumerStatefulWidget {
  const FinanceApplicationActionSurface({
    super.key,
    required this.application,
    required this.mode,
    this.invoiceId,
    this.resumeDraftId,
  });
  final Map<String, dynamic> application;
  final String mode;
  final String? invoiceId, resumeDraftId;
  @override
  ConsumerState<FinanceApplicationActionSurface> createState() =>
      _ActionState();
}

class _ActionState extends ConsumerState<FinanceApplicationActionSurface>
    with FormDraftMixin<FinanceApplicationActionSurface> {
  final _text = <String, TextEditingController>{};
  Map<String, dynamic> _refs = {};
  List<Map<String, dynamic>> _styles = [], _feeStyles = [];
  Map<String, dynamic>? _sent;
  String? _account, _style, _feeStyle, _employee, _invoiceResult, _error;
  String _purpose = 'ORDINARY_EXPENSE';
  bool _loading = true, _saving = false;
  TaskClaimSession? _claim;
  TextEditingController _c(String key) =>
      _text.putIfAbsent(key, () => TextEditingController());
  String get _id => widget.application['id'].toString();
  bool get _review =>
      {'approve', 'reject', 'invoice-verification'}.contains(widget.mode);
  bool get _zero =>
      widget.application['source_kind'] == 'PAYROLL_BATCH' &&
      RegExp(
        r'^0(?:\.0+)?$',
      ).hasMatch(widget.application['amount_original']?.toString() ?? '');
  FormDraftDescriptor get _descriptor => switch (widget.mode) {
    'execute' => FormDraftCatalog.financeApplicationExecute,
    'confirm' || 'unconfirm' => FormDraftCatalog.financeApplicationConfirm,
    'reverse' => FormDraftCatalog.financeApplicationReverse,
    'assign' => FormDraftCatalog.financeApplicationAssignment,
    'submit' || 'withdraw' =>
      widget.application['source_kind'] == 'EXPENSE_CLAIM'
          ? FormDraftCatalog.financeApplicationExpenseOwner
          : widget.application['source_kind'] == 'PAYROLL_BATCH'
          ? FormDraftCatalog.financeApplicationPayrollOwner
          : FormDraftCatalog.financeApplicationOwner,
    _ => FormDraftCatalog.financeApplicationReview,
  };
  @override
  FormDraftSpec get formDraftSpec => _descriptor.spec(
    route: '/finance/applications/$_id',
    routeParameters: {'action': widget.mode, 'invoiceId': ?widget.invoiceId},
    title:
        '${widget.application['kindLabel']} · ${financeApplicationActionLabel(widget.mode, widget.application)}',
  );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _saving;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => _text.values;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'id': _id,
    'mode': widget.mode,
    'sourceFingerprint': widget.application['source_fingerprint'],
    'version': widget.application['row_version'],
    'text': {for (final e in _text.entries) e.key: e.value.text},
    'account': _account,
    'style': _style,
    'feeStyle': _feeStyle,
    'employee': _employee,
    'invoiceResult': _invoiceResult,
    'purpose': _purpose,
    'sent': _sent,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['id'] != _id || data['mode'] != widget.mode) {
      throw const FormatException('原申请或动作已变化');
    }
    _sent = data['sent'] is Map ? financeApplicationMap(data['sent']) : null;
    if (data['sourceFingerprint'] != widget.application['source_fingerprint'] ||
        data['version'] != widget.application['row_version']) {
      if (_sent == null) {
        throw const FormatException('原申请内容或版本已变化，原输入已保留，请先核对当前申请');
      }
    }
    for (final e in financeApplicationMap(data['text']).entries) {
      _c(e.key).text = e.value?.toString() ?? '';
    }
    _account = data['account']?.toString();
    _style = data['style']?.toString();
    _feeStyle = data['feeStyle']?.toString();
    _employee = data['employee']?.toString();
    _invoiceResult = data['invoiceResult']?.toString();
    _purpose = data['purpose']?.toString() ?? _purpose;
    if (widget.mode == 'execute') await _loadStyles();
  }

  @override
  void initState() {
    super.initState();
    for (final k in [
      'reason',
      'paymentDate',
      'bankBookedAt',
      'bankReference',
      'bankAmount',
      'bankFee',
      'exchangeRate',
    ]) {
      _c(k);
    }
    _c('paymentDate').text = ChinaDateTime.today().toIso8601String().substring(
      0,
      10,
    );
    _c('bankFee').text = '0';
    _c('bankAmount').text =
        widget.application['amount_original']?.toString() ?? '';
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _claimChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadStyles() async {
    final scope = await captureFormDraftRequestScope();
    final api = ref.read(apiClientProvider);
    final values = await scope.run(
      () => Future.wait([
        api.get(
          '/finance/accounting-expense-styles',
          query: {'postingPurpose': _purpose},
        ),
        api.get(
          '/finance/accounting-expense-styles',
          query: {'postingPurpose': 'ORDINARY_EXPENSE'},
        ),
      ]),
    );
    if (mounted && scope.isCurrent) {
      setState(() {
        _styles = financeApplicationRows(values[0]['items']);
        _feeStyles = financeApplicationRows(values[1]['items']);
      });
    }
  }

  Future<void> _load() async {
    try {
      final scope = await captureFormDraftRequestScope();
      if (widget.mode == 'execute') {
        _refs = await scope.run(
          () => ref
              .read(apiClientProvider)
              .get('$financeApplicationsApi/references'),
        );
        await _loadStyles();
        final base = financeApplicationRows(_refs['currencies']).any(
          (r) =>
              r['id'] == widget.application['currency_id'] &&
              r['baseCurrency'] == true,
        );
        if (base) _c('exchangeRate').text = '1';
      }
      if (!mounted || !scope.isCurrent) return;
      await initializeFormDraft();
      if (_review && _sent == null) {
        _claim = TaskClaimSession(
          ref.read(taskClaimRepositoryProvider),
          strict: true,
          isCurrentSession: () => mounted && formDraftIdentityIsCurrent,
        )..addListener(_claimChanged);
        await _claim!.claimAll('FINANCE_APPLICATION_REVIEW', [_id]);
      }
      if (mounted && scope.isCurrent) setState(() => _loading = false);
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() {
          _loading = false;
          _error = humanErrorMessage(e) ?? '当前动作未准备好';
        });
      }
    }
  }

  Map<String, dynamic> _payload() => {
    'requestId': const Uuid().v4(),
    'expectedVersion': widget.application['row_version'],
    'sourceFingerprint': widget.application['source_fingerprint'],
    'expectedClaimId': _claim?.claimIdFor('FINANCE_APPLICATION_REVIEW', _id),
    'reason': _c('reason').text,
    if (widget.mode == 'execute') ...{
      'accountId': _account,
      'paymentDate': _c('paymentDate').text.trim(),
      'bankBookedAt': _c('bankBookedAt').text.trim(),
      'bankReference': _c('bankReference').text,
      'bankAmount': _zero ? null : _c('bankAmount').text.trim(),
      'bankFee': _zero ? null : _c('bankFee').text.trim(),
      'bankFeeStyleId': _feeStyle,
      'expenseStyleId': _style,
      'exchangeRate': _c('exchangeRate').text.trim(),
      'postingPurpose': _purpose,
    },
    if (widget.mode == 'assign') 'employeeIds': [_employee],
    if (widget.mode == 'invoice-verification') ...{
      'invoiceId': widget.invoiceId,
      'nativeVersion': financeApplicationMap(
        widget.application['expenseClaim'],
      )['version'],
      'result': _invoiceResult,
      'remark': _c('reason').text,
    },
  };
  Future<void> _save() async {
    if (_saving || !formDraftIdentityIsCurrent) return;
    setState(() => _saving = true);
    var mayPublish = () => mounted && formDraftIdentityIsCurrent;
    try {
      if (_sent == null &&
          _review &&
          !await (_claim?.validateForDecision() ?? Future.value(false))) {
        return;
      }
      final scope = await captureFormDraftRequestScope();
      mayPublish = () => mounted && scope.isCurrent;
      if (!mayPublish()) return;
      _sent ??= _payload();
      await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post('$financeApplicationsApi/$_id/${widget.mode}', body: _sent),
        ),
      );
      if (!mayPublish()) return;
      await completeFormDraft();
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted && mayPublish()) {
        if (!formDraftHasUnknownSubmission) _sent = null;
        context.appApiError(error, fallback: '处理结果待确认，原输入和请求编号已保留');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _receipt() async {
    if (_sent == null || _saving) return;
    final scope = await captureFormDraftRequestScope();
    setState(() => _saving = true);
    try {
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .get(
              '$financeApplicationsApi/$_id/operations/${_sent!['requestId']}',
            ),
      );
      if (!mounted || !scope.isCurrent) return;
      if (result['found'] == true) {
        await completeFormDraft();
        if (mounted) Navigator.pop(context, true);
      } else {
        context.appInfo('尚未读到已完成回执，请保留原请求，可重试原请求继续核对。');
      }
    } catch (e) {
      if (mounted && scope.isCurrent) context.appApiError(e);
    } finally {
      if (mounted && scope.isCurrent) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _claim?.removeListener(_claimChanged);
    unawaited(_claim?.releaseAll() ?? Future.value());
    _claim?.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final editable = !_saving && _sent == null && formDraftIdentityIsCurrent;
    return withFormDraft(
      Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDialogHeader(
              padding: EdgeInsets.zero,
              title: Text(
                financeApplicationActionLabel(widget.mode, widget.application),
                style: Theme.of(context).textTheme.titleLarge,
              ),
              showCloseButton: true,
              onClose: _saving ? null : () => Navigator.pop(context),
            ),
            Text(
              '${widget.application['application_no']}　${widget.application['title']}',
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        if (_error != null) Text(_error!),
                        if (_review && _claim?.isReady != true && _sent == null)
                          Text(_claim?.failureMessage ?? '当前节点未取得本人有效认领'),
                        if (widget.mode == 'execute') ...[
                          if (_zero)
                            const Text('原工资实发为0：按真实计提/扣款清偿核对，不登记0元银行付款。')
                          else ...[
                            UtenDropdownField(
                              label: '实际付款账户',
                              value: _account,
                              items: [
                                for (final r in financeApplicationRows(
                                  _refs['accounts'],
                                ))
                                  UtenDropdownItem(
                                    value: r['id'].toString(),
                                    label: '${r['code']} ${r['name']}',
                                  ),
                              ],
                              enabled: editable,
                              onChanged: editable
                                  ? (v) => setState(() {
                                      _account = v;
                                      markFormDraftChanged();
                                    })
                                  : (_) {},
                            ),
                            const SizedBox(height: 12),
                            for (final e in const {
                              'bankBookedAt': '实际付款时间（含 +08:00 时区）',
                              'bankReference': '银行流水号/现金签收依据',
                              'bankAmount': '账户实际扣款原币',
                              'bankFee': '账户原币银行手续费',
                              'exchangeRate': '申请原币记账汇率',
                            }.entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: UtenInput(
                                  label: e.value,
                                  controller: _c(e.key),
                                  enabled: editable,
                                ),
                              ),
                          ],
                          UtenInput(
                            label: _zero ? '清偿/核对日期' : '实际付款日期',
                            controller: _c('paymentDate'),
                            enabled: editable,
                            info: '按中国业务日期填写 YYYY-MM-DD',
                          ),
                          const SizedBox(height: 12),
                          if (widget.application['source_kind'] !=
                                  'PAYROLL_BATCH' &&
                              (widget.application['source_kind'] ==
                                      'EXPENSE_CLAIM' ||
                                  financeApplicationMap(
                                        widget.application['requested_payload'],
                                      )['paymentNature'] ==
                                      'GENERAL_EXPENSE')) ...[
                            UtenDropdownField(
                              label: '支出类型',
                              value: _purpose,
                              items: const [
                                UtenDropdownItem(
                                  value: 'ORDINARY_EXPENSE',
                                  label: '普通费用',
                                ),
                                UtenDropdownItem(
                                  value: 'MANUFACTURING_COST',
                                  label: '制造费用',
                                ),
                              ],
                              allowClear: false,
                              enabled: editable,
                              onChanged: editable
                                  ? (v) {
                                      if (v != null) {
                                        setState(() {
                                          _purpose = v;
                                          _style = null;
                                          markFormDraftChanged();
                                        });
                                        unawaited(_loadStyles());
                                      }
                                    }
                                  : (_) {},
                            ),
                            const SizedBox(height: 12),
                            UtenDropdownField(
                              label: '明确支出科目',
                              value: _style,
                              items: [
                                for (final r in _styles)
                                  UtenDropdownItem(
                                    value: r['id'].toString(),
                                    label: '${r['code']} ${r['name']}',
                                  ),
                              ],
                              enabled: editable,
                              onChanged: editable
                                  ? (v) => setState(() {
                                      _style = v;
                                      markFormDraftChanged();
                                    })
                                  : (_) {},
                            ),
                            const SizedBox(height: 12),
                          ],
                          if (!_zero)
                            UtenDropdownField(
                              label: '手续费科目（有手续费时）',
                              value: _feeStyle,
                              items: [
                                for (final r in _feeStyles)
                                  UtenDropdownItem(
                                    value: r['id'].toString(),
                                    label: '${r['code']} ${r['name']}',
                                  ),
                              ],
                              enabled: editable,
                              onChanged: editable
                                  ? (v) => setState(() {
                                      _feeStyle = v;
                                      markFormDraftChanged();
                                    })
                                  : (_) {},
                            ),
                        ],
                        if (widget.mode == 'assign')
                          BusinessEmployeePicker(
                            purpose: EmployeeReferencePurpose
                                .financeApplicationReviewer,
                            selectedId: _employee,
                            label: '当前节点明确办理人员',
                            statuses: const {'active', 'probation', 'onLeave'},
                            enabled: editable,
                            onChanged: (v) => setState(() {
                              _employee = v?.id;
                              markFormDraftChanged();
                            }),
                          ),
                        if (widget.mode == 'invoice-verification')
                          UtenDropdownField(
                            label: '原发票核验结论',
                            value: _invoiceResult,
                            items: const [
                              UtenDropdownItem(
                                value: 'VERIFIED_MANUAL',
                                label: '人工查验一致',
                              ),
                              UtenDropdownItem(
                                value: 'MISMATCH',
                                label: '查验不符',
                              ),
                            ],
                            enabled: editable,
                            onChanged: editable
                                ? (v) => setState(() {
                                    _invoiceResult = v;
                                    markFormDraftChanged();
                                  })
                                : (_) {},
                          ),
                        const SizedBox(height: 12),
                        UtenInput(
                          label: widget.mode == 'invoice-verification'
                              ? '查验渠道、日期及结果依据'
                              : '处理意见/依据',
                          controller: _c('reason'),
                          maxLines: 4,
                          enabled: editable,
                        ),
                      ],
                    ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                if (_sent != null)
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _saving ? null : _receipt,
                    child: const Text('读取原请求回执'),
                  ),
                UtenButton(
                  onPressed:
                      _saving ||
                          _loading ||
                          (_review && _sent == null && _claim?.isReady != true)
                      ? null
                      : _save,
                  child: Text(
                    _sent != null
                        ? '重试原请求'
                        : financeApplicationActionLabel(
                            widget.mode,
                            widget.application,
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
