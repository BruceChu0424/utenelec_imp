import '../../../shared/formatters/financial_amount_validation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/router/editor_resource_key.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/widgets/editor_identity_notice.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../basic_data/widgets/uten_supplier_picker.dart';
import '../models/business_application.dart';
import '../providers/business_application_providers.dart';
import '../repositories/business_application_repository.dart';

/// 四种申请共用编辑与草稿生命周期，字段差异由申请类型表达。
class BusinessApplicationEditPage extends ConsumerStatefulWidget {
  const BusinessApplicationEditPage({super.key, this.applicationId, this.kind});
  final String? applicationId;
  final String? kind;
  @override
  ConsumerState<BusinessApplicationEditPage> createState() =>
      _BusinessApplicationEditPageState();
}

class _BusinessApplicationEditPageState
    extends ConsumerState<BusinessApplicationEditPage>
    with FormDraftMixin<BusinessApplicationEditPage> {
  final _controllers = <String, TextEditingController>{
    for (final key in [
      'title',
      'amount',
      'reason',
      'destination',
      'transport',
      'companions',
      'payee',
      'paymentUnit',
      'remark',
    ])
      key: TextEditingController(),
  };
  String _id = const Uuid().v4();
  String? _createdDocId;
  late String _kind;
  String? _supplierId;
  String? _supplierName;
  DateTime? _start;
  DateTime? _end;
  bool _busy = false;
  bool _initialized = false;
  bool _documentIdentityChanged = false;
  late final Key _openedDocumentIdentity;
  Key get _documentIdentity => editorResourceKey(
    Uri(path: 'application-editor'),
    sourceIdentity: {
      'id': widget.applicationId,
      'kind': widget.kind ?? 'TRAVEL',
    },
  );
  @override
  bool get formDraftIdentityIsCurrent =>
      super.formDraftIdentityIsCurrent && !_documentIdentityChanged;
  int? _version;
  BusinessApplication? _originalApplication;

  bool get _editing => widget.applicationId != null;
  bool get _travel => _kind == 'TRAVEL';
  bool get _supplierTarget =>
      _kind == 'SUPPLIER_PAYMENT' || _kind == 'PREPAYMENT';
  String get _kindLabel => businessApplicationKinds[_kind]!;
  String _text(String key) => _controllers[key]!.text.trim();

  @override
  bool get formDraftEnabled => !_editing;
  @override
  bool get formDraftBusy => _busy;
  // The recovery action only reads the original UUID. It never replays create.
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec =>
      (ref.read(currentPermissionsProvider).contains(Perm.applicationApply)
              ? FormDraftCatalog.businessApplication
              : FormDraftCatalog.applicationKinds[_kind]!)
          .spec(
            title: _kindLabel,
            route: '/applications/new?kind=$_kind',
            draftKind: 'business_application_$_kind',
          );
  @override
  Iterable<Listenable> get formDraftListenables => _controllers.values;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'id': _id,
    'createdDocId': _createdDocId,
    'kind': _kind,
    for (final entry in _controllers.entries) entry.key: entry.value.text,
    'supplierId': _supplierId,
    'supplierName': _supplierName,
    'startDate': _start == null ? null : _date(_start!),
    'endDate': _end == null ? null : _date(_end!),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final kind = data['kind'];
    if (!businessApplicationKinds.containsKey(kind)) {
      throw const FormatException('申请类型已变化，请核对草稿');
    }
    _kind = kind as String;
    _id = data['id'] as String? ?? _id;
    _createdDocId = data['createdDocId'] as String?;
    for (final entry in _controllers.entries) {
      entry.value.text = data[entry.key]?.toString() ?? '';
    }
    _supplierId = data['supplierId'] as String?;
    _supplierName = data['supplierName'] as String?;
    _start = DateTime.tryParse(data['startDate']?.toString() ?? '');
    _end = DateTime.tryParse(data['endDate']?.toString() ?? '');
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _openedDocumentIdentity = _documentIdentity;
    startFormDraftIdentityGuard();
    _kind = businessApplicationKinds.containsKey(widget.kind)
        ? widget.kind!
        : 'TRAVEL';
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void didUpdateWidget(covariant BusinessApplicationEditPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_documentIdentity != _openedDocumentIdentity) {
      _documentIdentityChanged = true;
    }
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _prefill(BusinessApplication? application) {
    if (_initialized || application == null) return;
    _initialized = true;
    _originalApplication = application;
    _id = application.id;
    _version = application.version;
    _kind = application.kind;
    _controllers['title']!.text = application.title;
    _controllers['amount']!.text = application.amount;
    for (final entry in _controllers.entries) {
      if (entry.key != 'title' && entry.key != 'amount') {
        entry.value.text = application.fields[entry.key]?.toString() ?? '';
      }
    }
    _supplierId = application.fields['supplierId'] as String?;
    _supplierName = application.fields['supplierName'] as String?;
    _start = DateTime.tryParse(
      application.fields['startDate']?.toString() ?? '',
    );
    _end = DateTime.tryParse(application.fields['endDate']?.toString() ?? '');
  }

  Future<void> _save() async {
    if (_busy || !formDraftIdentityIsCurrent) return;
    if (_text('title').isEmpty || _text('reason').isEmpty) {
      context.appWarning('请填写申请标题和事由');
      return;
    }
    final amount = _text('amount');
    final amountError = _travel && amount.isEmpty
        ? null
        : _travel
        ? validateNonNegativeFinanceAmount(amount)
        : validateFinanceAmount(amount);
    if (amountError != null) {
      context.appWarning(amountError);
      return;
    }
    if (_travel &&
        (_text('destination').isEmpty ||
            _start == null ||
            _end == null ||
            _end!.isBefore(_start!))) {
      context.appWarning('请填写目的地，并核对出差起止日期');
      return;
    }
    if (!_travel && _text('payee').isEmpty && !_supplierTarget) {
      context.appWarning('请填写收款人');
      return;
    }
    if (_kind == 'PREPAYMENT' && _supplierId == null) {
      context.appWarning('请选择预付款的收款供应商');
      return;
    }
    if (_kind == 'SUPPLIER_PAYMENT' &&
        (_supplierId == null || _text('paymentUnit').isEmpty)) {
      context.appWarning('请选择供应商并填写付款单位');
      return;
    }
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null || scope.readOnly) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    var invalidated = false;
    final subscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      _,
      next,
    ) {
      if (next != boundary) invalidated = true;
    });
    bool current() =>
        mounted &&
        !invalidated &&
        formDraftIdentityIsCurrent &&
        ref.read(sensitiveReadBoundaryProvider) == boundary;
    setState(() => _busy = true);
    try {
      final input = BusinessApplicationInput(
        id: _id,
        kind: _kind,
        title: _text('title'),
        amount: amount,
        expectedVersion: _version,
        fields: {
          for (final entry in _controllers.entries)
            if (entry.key != 'title' && entry.key != 'amount')
              entry.key: entry.value.text.trim(),
          if (_supplierId != null) 'supplierId': _supplierId,
          if (_supplierName != null) 'supplierName': _supplierName,
          if (_start != null) 'startDate': _date(_start!),
          if (_end != null) 'endDate': _date(_end!),
        },
      );
      final repository = ref.read(businessApplicationRepositoryProvider);
      // An uncertain create has one fixed identity. Reconcile it by reading;
      // never repeat the write because a network response did not arrive.
      final saved = await runSensitiveWrite<BusinessApplication>(
        ref,
        isCurrent: current,
        write: () async =>
            formDraftHasUnknownSubmission || _createdDocId != null
            ? await repository.get(_id)
            : _editing
            ? await repository.update(_id, input)
            : await runFormDraftSubmission(() => repository.create(input)),
      );
      if (!current()) return;
      if (saved.id != _id ||
          saved.kind != _kind ||
          saved.applicantId != ref.read(sessionProvider).user?.employeeId) {
        throw const FormatException('保存回执与原申请身份不一致，请保留草稿并核对');
      }
      _createdDocId = saved.id;
      await checkpointFormDraftAfterCreation();
      ref.invalidate(businessApplicationCountsProvider);
      refreshBadges(ref);
      ref.invalidate(businessApplicationDetailProvider(saved.id));
      await completeFormDraft();
      if (mounted && current()) {
        setState(() => _busy = false);
        context.replace('/applications/${saved.id}');
        context.appSuccess('申请已保存');
      }
    } catch (error) {
      if (mounted && current()) {
        setState(() => _busy = false);
        context.appApiError(error, fallback: '保存失败，原输入已保留');
      }
    } finally {
      subscription.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(
    String key,
    String label, {
    int maxLines = 1,
    String? info,
    bool money = false,
  }) => TextField(
    controller: _controllers[key],
    readOnly:
        key == 'amount' && (_originalApplication?.continuedOriginal ?? false),
    maxLines: maxLines,
    maxLength: key == 'title'
        ? 200
        : key == 'amount'
        ? 200
        : 2000,
    keyboardType: money
        ? const TextInputType.numberWithOptions(decimal: true)
        : null,
    decoration: UtenInputDecoration(
      InputDecoration(labelText: label, counterText: ''),
      info: info,
    ),
  );

  Future<void> _reloadDetail() async {
    if (_busy || widget.applicationId == null) return;
    setState(() => _busy = true);
    try {
      ref.invalidate(businessApplicationDetailProvider(widget.applicationId!));
      await ref.read(
        businessApplicationDetailProvider(widget.applicationId!).future,
      );
    } catch (error) {
      if (mounted) {
        setState(() => _busy = false);
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _applicationFields() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      UtenFormGrid(
        key: const Key('application-primary-fields'),
        columns: 3,
        maxColumns: _kind == 'SUPPLIER_PAYMENT' ? 2 : 3,
        minFieldWidth: 280,
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s16,
        children: [
          _field('title', '申请标题 *'),
          if (_travel) _field('destination', '出差目的地 *'),
          if (_supplierTarget &&
              _originalApplication?.continuedOriginal == true)
            TextFormField(
              initialValue: _supplierName,
              readOnly: true,
              decoration: const UtenInputDecoration(
                InputDecoration(labelText: '原收款供应商'),
                info: '保留已审阅原供应商及其原币义务。',
              ),
            ),
          if (_supplierTarget &&
              _originalApplication?.continuedOriginal != true)
            SupplierPickerField(
              label: '收款供应商',
              required: true,
              initialId: _supplierId,
              initialName: _supplierName,
              onPick: () async {
                final supplier = await showUtenSupplierPicker(context, ref);
                if (mounted && supplier != null) {
                  setState(() {
                    _supplierName = supplier.name;
                    _controllers['payee']!.text = supplier.name ?? '';
                  });
                }
                return supplier;
              },
              onChanged: (id) {
                if (_originalApplication?.continuedOriginal == true &&
                    id != _supplierId) {
                  context.appWarning('原供应商须按已审阅义务保留');
                  return;
                }
                setState(() {
                  _supplierId = id;
                  if (id == null) {
                    _supplierName = null;
                    _controllers['payee']!.clear();
                  }
                });
              },
            ),
          if (!_travel && !_supplierTarget) _field('payee', '收款人 / 单位 *'),
          _field(
            'amount',
            _travel
                ? '预计费用（${_originalApplication?.amountUnit ?? '元'}）'
                : '申请金额（${_originalApplication?.amountUnit ?? '元'}）*',
            money: true,
            info: _kind == 'PREPAYMENT'
                ? '仅支持供应商预付款。获批后登记实际付款凭证，账务状态独立跟进；不会自动生成费用单，后续核销以财务预付台账为准。'
                : null,
          ),
          if (_travel) ...[
            UtenDateField(
              label: '开始日期',
              required: true,
              value: _start,
              onChanged: (value) => setState(() => _start = value),
            ),
            UtenDateField(
              label: '结束日期',
              required: true,
              value: _end,
              onChanged: (value) => setState(() => _end = value),
            ),
            _field('transport', '交通方式'),
            _field('companions', '同行人员'),
          ],
          if (_kind == 'SUPPLIER_PAYMENT') _field('paymentUnit', '付款单位 *'),
        ],
      ),
      const SizedBox(height: UtenSpacing.s16),
      UtenFormGrid(
        columns: 2,
        maxColumns: 2,
        minFieldWidth: 360,
        spacing: UtenSpacing.s16,
        runSpacing: UtenSpacing.s16,
        children: [
          _field('reason', _travel ? '出差事由 *' : '内容摘要 / 付款事由 *', maxLines: 3),
          _field('remark', '备注', maxLines: 3),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return EditorIdentityNotice(
        title: '申请填写',
        documentChanged: _documentIdentityChanged,
        onBack: () => backTo(context, defaultPath: '/applications'),
      );
    }
    final detail = _editing
        ? ref.watch(businessApplicationDetailProvider(widget.applicationId!))
        : null;
    _prefill(detail?.value);
    final application = detail?.value;
    final me = ref.watch(sessionProvider).user;
    final scope = ref.watch(authenticatedScopeProvider);
    final canEdit =
        scope != null &&
        !scope.readOnly &&
        (ref
                .watch(currentPermissionsProvider)
                .contains(Perm.applicationApply) ||
            ref
                .watch(currentPermissionsProvider)
                .contains(Perm.applicationKindApplyPermissions[_kind])) &&
        (!_editing ||
            application != null &&
                application.editable &&
                application.applicantId == me?.employeeId);
    final theme = Theme.of(context);
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '${_editing ? '编辑' : '新建'}$_kindLabel',
          showBackButton: true,
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: UtenContentContainer(
                child: ListView(
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s16,
                    bottom: UtenFloatingActionGroup.scrollClearance,
                  ),
                  children: [
                    if (detail?.isLoading == true)
                      const LinearProgressIndicator(),
                    if (detail?.hasError == true)
                      Center(
                        child: UtenButton(
                          onPressed: _busy ? null : _reloadDetail,
                          child: const Text('重新读取申请'),
                        ),
                      ),
                    if (!_editing || application != null)
                      AbsorbPointer(
                        absorbing:
                            _busy ||
                            !canEdit ||
                            formDraftHasUnknownSubmission ||
                            _createdDocId != null,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            border: Border.all(
                              color: theme.colorScheme.outlineVariant,
                            ),
                            borderRadius: UtenRadius.cardAll,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s20),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Row(
                                  children: [
                                    Text(
                                      '申请信息',
                                      style: theme.textTheme.titleMedium,
                                    ),
                                    const UtenFieldHintIcon(
                                      info:
                                          '保存后在详情补充相关凭证并提交审批。系统按申请类型匹配审批链，未批准的申请不能登记付款。',
                                      compact: true,
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: UtenSpacing.s24,
                                  runSpacing: UtenSpacing.s8,
                                  children: [
                                    Text(
                                      '申请人  ${application?.applicantName ?? me?.name ?? '—'}',
                                    ),
                                    Text(
                                      '部门  ${application?.departmentName ?? me?.department ?? '—'}',
                                    ),
                                    Text(
                                      '日期  ${_date(application?.createdAt ?? ChinaDateTime.today())}',
                                    ),
                                  ],
                                ),
                                if (application?.rejectReason
                                    case final reason?) ...[
                                  const SizedBox(height: UtenSpacing.s12),
                                  Text(
                                    '驳回原因：$reason',
                                    style: TextStyle(
                                      color: theme.colorScheme.error,
                                    ),
                                  ),
                                ],
                                const Divider(height: UtenSpacing.s32),
                                _applicationFields(),
                                const Divider(height: UtenSpacing.s32),
                                Row(
                                  children: [
                                    Text(
                                      '审批流程',
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    const UtenFieldHintIcon(
                                      info:
                                          '各节点分别授权。驳回必须填写原因，修订重提重新走完整审批；所有意见和历史记录会保留。',
                                      compact: true,
                                    ),
                                  ],
                                ),
                                Wrap(
                                  spacing: UtenSpacing.s8,
                                  runSpacing: UtenSpacing.s8,
                                  children: [
                                    for (final stage
                                        in businessApplicationApprovalRoles(
                                          _kind,
                                        ))
                                      Chip(label: Text(stage)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (_busy)
              const UtenBusyOverlay(title: '正在保存申请', showDoNotLeaveHint: false),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: canEdit
            ? UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    icon: formDraftHasUnknownSubmission
                        ? Icons.fact_check_outlined
                        : Icons.save_outlined,
                    isLoading: _busy,
                    onPressed: _busy ? null : _save,
                    child: Text(
                      formDraftHasUnknownSubmission && !_busy
                          ? '核对保存结果'
                          : '保存并补充凭证',
                    ),
                  ),
                ],
              )
            : null,
      ),
    );
  }
}

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
