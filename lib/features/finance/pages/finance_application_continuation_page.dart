import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/widgets/editor_identity_notice.dart';
import '../../applications/models/business_application.dart';
import 'finance_applications_page.dart';

/// Explicit source review. The old command and current confirmation are
/// separate durable requests, each retaining its own original identity.
class FinanceApplicationContinuationPage extends ConsumerStatefulWidget {
  const FinanceApplicationContinuationPage({
    super.key,
    required this.originId,
    required this.kind,
    this.originalCommand,
    this.resumeDraftId,
  });
  final String originId, kind;
  final String? originalCommand, resumeDraftId;
  @override
  ConsumerState<FinanceApplicationContinuationPage> createState() =>
      _ContinuationState();
}

class _ContinuationState
    extends ConsumerState<FinanceApplicationContinuationPage>
    with FormDraftMixin<FinanceApplicationContinuationPage> {
  final _payee = TextEditingController();
  final _paymentUnit = TextEditingController();
  String? _raw, _selectedKind, _reviewedCurrency;
  List<Map<String, dynamic>> _currencies = [];
  bool get _needsCurrency =>
      widget.kind == 'TRAVEL_APPLICATION' &&
      _original['amount_original'] != null &&
      _original['currency_id'] == null;
  int _version = -1;
  Map<String, dynamic> _review = {}, _original = {};
  Map<String, dynamic>? _confirm;
  bool _busy = false, _ready = false;
  late final String _openedOrigin = widget.originId;
  late final String _openedKind = widget.kind;
  late final String? _openedCommand = widget.originalCommand;
  bool get _expense =>
      const {'REIMBURSEMENT', 'TRAVEL_REIMBURSEMENT'}.contains(widget.kind);
  bool get _sameDocument =>
      widget.originId == _openedOrigin &&
      widget.kind == _openedKind &&
      widget.originalCommand == _openedCommand;
  @override
  bool get formDraftIdentityIsCurrent =>
      super.formDraftIdentityIsCurrent && _sameDocument;
  @override
  FormDraftSpec get formDraftSpec =>
      (_expense ||
                  (widget.kind == 'TRAVEL_APPLICATION' &&
                      ref
                          .read(currentPermissionsProvider)
                          .contains(Perm.expenseApply))
              ? FormDraftCatalog.financeApplicationExpenseContinuation
              : FormDraftCatalog.financeApplicationContinuation)
          .spec(
            route: '/finance/applications/${widget.originId}/continue',
            routeParameters: {'kind': widget.kind},
          );
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _confirm != null;
  @override
  Iterable<Listenable> get formDraftListenables => [_payee, _paymentUnit];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'originId': widget.originId,
    'kind': widget.kind,
    'originalCommand': _raw,
    'version': _version,
    'payee': _payee.text,
    'paymentUnit': _paymentUnit.text,
    'selectedBusinessKind': _selectedKind,
    'reviewedCurrencyId': _reviewedCurrency,
    'review': _review,
    'confirm': _confirm,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['originId'] != widget.originId || data['kind'] != widget.kind) {
      throw const FormatException('原申请身份已变化，草稿仍保留原身份');
    }
    _raw = data['originalCommand'] as String?;
    _version = (data['version'] as num?)?.toInt() ?? -1;
    _payee.text = data['payee']?.toString() ?? '';
    _paymentUnit.text = data['paymentUnit']?.toString() ?? '';
    _selectedKind = data['selectedBusinessKind'] as String?;
    _reviewedCurrency = data['reviewedCurrencyId'] as String?;
    _review = financeApplicationMap(data['review']);
    _confirm = data['confirm'] is Map
        ? financeApplicationMap(data['confirm'])
        : null;
  }

  @override
  void initState() {
    super.initState();
    _raw = widget.originalCommand;
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    await initializeFormDraft();
    if (!mounted || !formDraftIdentityIsCurrent) return;
    await _loadOriginal();
  }

  Future<void> _loadOriginal() async {
    if (_busy || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    var mayPublish = () => mounted && formDraftIdentityIsCurrent;
    try {
      final scope = await captureFormDraftRequestScope();
      mayPublish = () => mounted && scope.isCurrent;
      if (!mayPublish()) return;
      final api = ref.read(apiClientProvider);
      final receipt = await scope.run(
        () => api.get(
          '$financeApplicationsApi/continuation/${widget.originId}/receipt',
        ),
      );
      if (!mounted || !scope.isCurrent) return;
      if (receipt['found'] == true) {
        await _openResult(receipt);
        return;
      }
      try {
        final source = await scope.run(
          () => api.get('$financeApplicationsApi/${widget.originId}'),
        );
        if (!mounted || !scope.isCurrent) return;
        if (source['kind'] != widget.kind) {
          throw const FormatException('原申请类型与当前入口不一致，请从原记录重新打开');
        }
        _version = (source['row_version'] as num).toInt();
        _original = source;
        if (_needsCurrency) {
          final references = await scope.run(
            () => api.get('$financeApplicationsApi/references'),
          );
          if (!mounted || !scope.isCurrent) return;
          _currencies = financeApplicationRows(references['currencies']);
        }
      } on ApiException catch (error) {
        if (error.httpStatus != 404) rethrow;
        if (_raw == null) rethrow;
        _original = financeApplicationMap(jsonDecode(_raw!));
      }
      if (mounted && scope.isCurrent) setState(() => _ready = true);
    } catch (error) {
      if (mounted && mayPublish()) {
        context.appApiError(error, fallback: '原稿未读取完成，保留当前内容后重试查询');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare() async {
    if (_busy || _confirm != null || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    var mayPublish = () => mounted && formDraftIdentityIsCurrent;
    try {
      final scope = await captureFormDraftRequestScope();
      mayPublish = () => mounted && scope.isCurrent;
      if (!mayPublish()) return;
      final command = _raw == null
          ? <String, dynamic>{}
          : financeApplicationMap(jsonDecode(_raw!));
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .post(
              '$financeApplicationsApi/continuation/review',
              body: {
                'originId': widget.originId,
                'expectedVersion': _version,
                if (_raw != null) ...{
                  'originalCommand': _raw,
                  'originalRequestId': command['requestId'],
                },
                if (_selectedKind != null)
                  'selectedBusinessKind': _selectedKind,
                'reviewedCurrencyId': _reviewedCurrency,
                'fields': {
                  if (_payee.text.trim().isNotEmpty)
                    'payee': _payee.text.trim(),
                  if (_paymentUnit.text.trim().isNotEmpty)
                    'paymentUnit': _paymentUnit.text.trim(),
                },
              },
            ),
      );
      if (!mounted || !scope.isCurrent) return;
      if (result['found'] == true) {
        await _openResult(result);
        return;
      }
      setState(() => _review = result);
      markFormDraftChanged();
    } catch (error) {
      if (mounted && mayPublish()) {
        context.appApiError(error, fallback: '审阅未完成，原稿和补充内容已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    if (_busy || _review.isEmpty || !formDraftIdentityIsCurrent) return;
    setState(() => _busy = true);
    var mayPublish = () => mounted && formDraftIdentityIsCurrent;
    try {
      final scope = await captureFormDraftRequestScope();
      mayPublish = () => mounted && scope.isCurrent;
      if (!mayPublish()) return;
      _confirm ??= {
        'requestId': const Uuid().v4(),
        'reviewId': _review['reviewId'],
        'reviewedFingerprint': _review['reviewedFingerprint'],
      };
      final result = await runFormDraftSubmission(
        () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(
                '$financeApplicationsApi/continuation/confirm',
                body: _confirm,
              ),
        ),
      );
      if (!mounted || !scope.isCurrent) return;
      await _openResult(result);
    } catch (error) {
      if (mounted && mayPublish()) {
        if (!formDraftHasUnknownSubmission) _confirm = null;
        context.appApiError(error, fallback: '接续结果待确认，先查询原接续回执；原稿和本次编号已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openResult(Map<String, dynamic> result) async {
    final location = result['location']?.toString();
    if (location == null ||
        !RegExp(
          r'^/(?:applications|expense)/[0-9a-fA-F-]{36}$',
        ).hasMatch(location)) {
      throw const FormatException('接续回执地址无法核对，请保留原请求');
    }
    await completeFormDraft();
    if (mounted && formDraftIdentityIsCurrent) context.go(location);
  }

  void _changed() {
    if (_confirm == null && _review.isNotEmpty) setState(() => _review = {});
    markFormDraftChanged();
  }

  @override
  void dispose() {
    _payee.dispose();
    _paymentUnit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return EditorIdentityNotice(
        title: '原申请接续',
        documentChanged: !_sameDocument,
        onBack: () => context.go('/finance/applications'),
      );
    }
    final original = financeApplicationMap(_review['original']);
    final payload = financeApplicationMap(
      original.isEmpty ? _original['requested_payload'] : original['payload'],
    );
    final proposed = financeApplicationMap(_review['proposed']);
    final business = proposed['businessKind']?.toString();
    final amount = original['amountOriginal']?.toString();
    final unit =
        original['currencyCode']?.toString() ??
        original['currencyName']?.toString() ??
        '原币待核';
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '原申请接续',
          showBackButton: true,
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : _loadOriginal,
              child: const Text('查询接续回执'),
            ),
          ],
        ),
        body: Stack(
          children: [
            UtenContentContainer(
              child: ListView(
                children: [
                  Row(
                    children: [
                      Text(
                        '审阅原稿',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(width: 6),
                      const UtenFieldHintIcon(
                        info:
                            '保留原稿、原请求与原件；确认仅生成当前流程草稿。审批、实际付款和账务关联分别办理。结果未知时先查询回执。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_needsCurrency) ...[
                    UtenDropdownField(
                      label: '原稿金额币别',
                      value: _reviewedCurrency,
                      enabled: _confirm == null && !_busy,
                      items: [
                        for (final currency in _currencies)
                          UtenDropdownItem(
                            value: currency['id']?.toString(),
                            label:
                                '${currency['code'] ?? ''} ${currency['name'] ?? ''}',
                          ),
                      ],
                      onChanged: (value) {
                        setState(() => _reviewedCurrency = value);
                        _changed();
                      },
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (!_expense) ...[
                    UtenDropdownField(
                      label: '当前申请类别',
                      value: _selectedKind,
                      enabled: _confirm == null && !_busy,
                      items: [
                        for (final item in businessApplicationKinds.entries)
                          UtenDropdownItem(value: item.key, label: item.value),
                      ],
                      onChanged: (value) {
                        setState(() => _selectedKind = value);
                        _changed();
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _payee,
                      enabled: _confirm == null && !_busy,
                      onChanged: (_) => _changed(),
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '收款人 / 单位'),
                        info: '普通付款缺少收款人时在此明确补充，不按供应商姓名推断付款性质。',
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _paymentUnit,
                      enabled: _confirm == null && !_busy,
                      onChanged: (_) => _changed(),
                      decoration: const UtenInputDecoration(
                        InputDecoration(labelText: '付款单位'),
                        info: '原应付供应商付款须明确当前付款单位，原供应商、原币和逐项义务保持原依据。',
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  UtenButton(
                    onPressed: _busy || !_ready || _confirm != null
                        ? null
                        : _prepare,
                    child: const Text('审阅原稿'),
                  ),
                  if (_review.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    SelectableText('原申请：${original['title'] ?? ''}'),
                    SelectableText('申请日期：${original['requestedDate'] ?? '—'}'),
                    SelectableText(
                      '原申请金额：${amount == null ? '— / 不适用' : '$amount $unit'}',
                    ),
                    if (payload['destination'] != null)
                      SelectableText('出差地点：${payload['destination']}'),
                    if (payload['travelStart'] != null)
                      SelectableText(
                        '出差日期：${payload['travelStart']} 至 ${payload['travelEnd']}',
                      ),
                    for (final line in financeApplicationRows(payload['lines']))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: SelectableText(
                          '${line['label'] ?? ''}  ${line['amountOriginal'] ?? '—'} $unit',
                        ),
                      ),
                    for (final file in financeApplicationRows(
                      _review['attachments'],
                    ))
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text('原稿凭证：${file['originalName'] ?? ''}'),
                      ),
                    const SizedBox(height: 16),
                    Text(
                      '当前流程：${_expense ? '原报销单按当前报销审批继续' : businessApplicationKinds[business] ?? business ?? ''}',
                    ),
                    if (business != null)
                      Text(
                        businessApplicationApprovalRoles(business).join(' → '),
                      ),
                    const SizedBox(height: 16),
                    UtenButton(
                      onPressed: _busy ? null : _continue,
                      child: Text(_confirm == null ? '确认按当前流程继续' : '重试本次接续确认'),
                    ),
                  ],
                ],
              ),
            ),
            if (_busy)
              const UtenBusyOverlay(
                title: '正在核对原申请',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
      ),
    );
  }
}
