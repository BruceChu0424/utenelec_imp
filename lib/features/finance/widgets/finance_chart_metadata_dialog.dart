import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../shared/finance_original_command.dart';

/// A short editor owns its durable original command through completion/recovery.
Future<bool> showFinanceChartMetadataDialog(
  BuildContext context, {
  required String code,
  Map<String, dynamic>? account,
  String? resumeDraftId,
}) async {
  if (!RegExp(r'^[0-9]{1,32}$').hasMatch(code) ||
      account == null && resumeDraftId == null ||
      account != null && account['code']?.toString() != code) {
    throw const FormatException('科目名称草稿缺少原科目编码或来源');
  }
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ChartMetadataDialog(
          code: code,
          account: account,
          resumeDraftId: resumeDraftId,
        ),
      ) ??
      false;
}

class _ChartMetadataDialog extends ConsumerStatefulWidget {
  const _ChartMetadataDialog({
    required this.code,
    this.account,
    this.resumeDraftId,
  });
  final String code;
  final Map<String, dynamic>? account;
  final String? resumeDraftId;
  @override
  ConsumerState<_ChartMetadataDialog> createState() =>
      _ChartMetadataDialogState();
}

class _ChartMetadataDialogState extends ConsumerState<_ChartMetadataDialog>
    with FormDraftMixin<_ChartMetadataDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(), _reference = TextEditingController();
  String _requestId = const Uuid().v4(), _originalName = '';
  int _expectedVersion = -1;
  bool _ready = false, _busy = false;
  Map<String, dynamic>? _sent;
  Map<String, dynamic>? _retiredReceipt;
  bool _needsCurrentReview = false, _recoveryMenuOpen = false;
  String get _path => '/finance/chart/${widget.code}/metadata';
  String get _receiptPath => '$_path/operations/$_requestId';
  FinanceOriginalCommand _command(Map<String, dynamic> body) =>
      FinanceOriginalCommand(
        actorId: ref.read(authenticatedScopeProvider)?.userId ?? '',
        operation: 'CHART_METADATA_UPDATE',
        method: 'PUT',
        path: _path,
        body: body,
      );

  bool get _canRead {
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.financeReportView) &&
        permissions.contains(Perm.financeViewAll);
  }

  bool get _canWrite =>
      financeOriginalIdentityCanMutate(ref.read(authenticatedScopeProvider)) &&
      _canRead &&
      ref.read(currentPermissionsProvider).contains(Perm.paymentStyleEdit);
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.financeChartMetadata.spec(
    routeParameters: {'code': widget.code},
    title: '修改科目名称 · ${widget.code}',
  );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  bool get formDraftRequiresOriginalReceipt => _sent != null;
  @override
  Iterable<Listenable> get formDraftListenables => [_name, _reference];
  @override
  Object formDraftReadBoundaryIdentity(SensitiveReadBoundary boundary) =>
      SensitiveReadBoundary(
        identity: boundary.identity,
        api: boundary.api,
        permissions: {...boundary.permissions}..remove(Perm.paymentStyleEdit),
        superAdmin: boundary.superAdmin,
      );

  Map<String, dynamic> _payload() => {
    'requestId': _requestId,
    'expectedVersion': _expectedVersion,
    'name': _name.text.trim(),
    'sourceReference': _reference.text.trim(),
  };
  @override
  Map<String, dynamic> captureFormDraft() => {
    'code': widget.code,
    'originalName': _originalName,
    'requestId': _requestId,
    'expectedVersion': _expectedVersion,
    'name': _name.text,
    'sourceReference': _reference.text,
    'sent': _sent,
    'requestRecovery': {
      'retiredReceipt': _retiredReceipt,
      'needsCurrentReview': _needsCurrentReview,
    },
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final request = data['requestId'], version = data['expectedVersion'];
    if (data['code'] != widget.code ||
        data['originalName'] is! String ||
        data['name'] is! String ||
        data['sourceReference'] is! String ||
        request is! String ||
        !Uuid.isValidUUID(fromString: request) ||
        version is! int ||
        version < 0) {
      throw StateError('科目名称草稿的原身份、版本或输入不完整');
    }
    _requestId = request;
    _expectedVersion = version;
    _originalName = data['originalName'] as String;
    _name.text = data['name'] as String;
    _reference.text = data['sourceReference'] as String;
    _sent = data['sent'] is Map
        ? Map<String, dynamic>.from(data['sent'] as Map)
        : null;
    if (_sent != null) {
      final expected = _payload();
      if (_sent!.length != expected.length ||
          expected.entries.any((entry) => _sent![entry.key] != entry.value)) {
        throw StateError('科目名称原请求与草稿输入不一致，不能重新解释原提交');
      }
    }
    final recovery = data['requestRecovery'];
    _needsCurrentReview =
        recovery is Map && recovery['needsCurrentReview'] == true;
    _retiredReceipt = recovery is Map && recovery['retiredReceipt'] is Map
        ? Map<String, dynamic>.from(recovery['retiredReceipt'] as Map)
        : null;
    if (_retiredReceipt != null) {
      final body = _retiredReceipt!['requestBody'];
      if (body is! Map ||
          _retiredReceipt!['outcome'] != 'CANCELLED_UNWRITTEN') {
        throw StateError('科目名称原请求停止证明不完整');
      }
      _command(Map<String, dynamic>.from(body)).verify(_retiredReceipt!);
    }
  }

  @override
  void initState() {
    super.initState();
    _originalName = widget.account?['name']?.toString() ?? '';
    _expectedVersion = (widget.account?['version'] as num?)?.toInt() ?? -1;
    _name.text = _originalName;
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_canRead) {
        await initializeFormDraft();
      }
      if (mounted) setState(() => _ready = true);
    });
  }

  Future<void> _save() async {
    if (!_ready ||
        _busy ||
        _recoveryMenuOpen ||
        _needsCurrentReview ||
        !formDraftIdentityIsCurrent ||
        !_canWrite) {
      return;
    }
    if (_sent == null &&
        (_expectedVersion < 0 || _form.currentState?.validate() != true)) {
      return;
    }
    final hadPending = _sent != null;
    var dispatched = false;
    setState(() => _busy = true);
    try {
      if (_sent == null && _retiredReceipt?['requestId'] == _requestId) {
        _requestId = const Uuid().v4();
      }
      _sent ??= _payload();
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final result = await runFormDraftSubmission(
        () => UtenBusyOverlay.run(
          context,
          title: '正在保存科目名称',
          action: () => scope.run(() async {
            final api = ref.read(apiClientProvider);
            dispatched = true;
            final raw = await api.put(_path, body: _sent);
            if (!scope.isCurrent || !formDraftIdentityIsCurrent) {
              throw StateError('原财务身份已变化');
            }
            if (raw['status'] == 'UPDATED') _verifyResult(raw);
            return _command(_sent!).readReceipt(api, _receiptPath);
          }),
        ),
        isDefiniteRejection: (_) => false,
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptReceipt(result);
    } catch (error) {
      if (!dispatched && !hadPending) {
        _sent = null;
        try {
          await releaseFormDraftBeforeDispatch();
        } catch (_) {}
      } else {
        try {
          await saveFormDraftNow();
        } catch (_) {}
      }
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '科目名称结果待核对，原内容与请求已保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _verifyResult(Map<String, dynamic> result) {
    if (_sent == null ||
        result['status'] != 'UPDATED' ||
        result['requestId'] != _requestId ||
        result['code'] != widget.code ||
        result['name'] != _sent!['name'] ||
        result['sourceReference'] != _sent!['sourceReference']) {
      throw StateError('科目名称回执与原请求不一致，原请求仍需核对');
    }
  }

  Future<void> _acceptReceipt(Map<String, dynamic> receipt) async {
    if (receipt['found'] != true) {
      context.appWarning('尚未取得原修改回执，原内容和请求继续保留。');
      return;
    }
    _command(_sent!).verify(receipt);
    if (receipt['outcome'] == 'CANCELLED_UNWRITTEN') {
      _retiredReceipt = Map<String, dynamic>.from(receipt);
      _sent = null;
      _needsCurrentReview = true;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (mounted) setState(() {});
      return;
    }
    final result = receipt['result'];
    if (result is! Map) throw StateError('原科目名称成功回执不完整');
    _verifyResult(Map<String, dynamic>.from(result));
    await completeFormDraft();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _receipt() async {
    if (!_ready ||
        _busy ||
        _sent == null ||
        !formDraftIdentityIsCurrent ||
        !_canRead) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final receipt = await UtenBusyOverlay.run(
        context,
        title: '正在核对原科目名称修改',
        action: () => scope.run(
          () => _command(
            _sent!,
          ).readReceipt(ref.read(apiClientProvider), _receiptPath),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptReceipt(receipt);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '原修改结果仍待核对，原内容和请求继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelUnwritten() async {
    if (_busy || _sent == null || !_canRead || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final receipt = await UtenBusyOverlay.run(
        context,
        title: '正在核实原科目名称请求',
        action: () => scope.run(
          () => _command(
            _sent!,
          ).cancelUnwritten(ref.read(apiClientProvider), _receiptPath),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptReceipt(receipt);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '停止结果仍待核对，原修改请求继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewCurrent() async {
    if (_busy || _sent != null || !_canRead || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final current = await UtenBusyOverlay.run(
        context,
        title: '正在读取当前科目名称',
        action: () => scope.run(() => ref.read(apiClientProvider).get(_path)),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      if (current['code'] != widget.code ||
          current['name'] is! String ||
          current['version'] is! int) {
        throw StateError('当前科目身份或版本依据不完整');
      }
      final adopted = await showFinanceCurrentVersionReview(
        context,
        rows: [('科目名称', _name.text, current['name'] as String)],
      );
      if (!adopted ||
          !mounted ||
          !scope.isCurrent ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      _expectedVersion = current['version'] as int;
      _needsCurrentReview = false;
      await saveFormDraftNow();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '当前科目尚未核对完成，原输入继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy || _recoveryMenuOpen) return;
    if (_sent != null) {
      try {
        await saveFormDraftNow();
        if (mounted && formDraftIdentityIsCurrent) {
          Navigator.pop(context, false);
        }
      } catch (error) {
        if (mounted) context.appApiError(error, fallback: '原修改请求尚未保存，请保留当前窗口');
      }
      return;
    }
    if (await confirmFormDraftExit() && mounted) {
      Navigator.pop(context, false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    final current = formDraftIdentityIsCurrent && _canRead;
    if (!current) {
      return UtenAlertDialog(
        title: const Text('访问范围已变化'),
        content: const Text('原科目名称草稿已保留，请以具备公司财务读取权限的原账号重新打开。'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    final editable = current && _canWrite && _ready && !_busy && _sent == null;
    return withFormDraft(
      UtenAlertDialog(
        key: const Key('finance-chart-metadata-editor'),
        maxWidth: 600,
        title: UtenDialogTitleWithHint(
          title: Text('修改科目名称 · ${widget.code}'),
          info: _sent == null
              ? (_needsCurrentReview
                    ? '原请求已确认停止，原名称与依据已保留。核对当前科目后采用当前版本，再由你点击保存新请求。'
                    : '保留原科目编码、核算科目身份、报表对应和原始来源。修改依据与修改前后名称一并保留。')
              : '原修改结果待核对，内容与原请求已保存。请核对回执或重试原请求；不能更换版本另发一次。',
        ),
        content: SizedBox(
          width: 520,
          child: Form(
            key: _form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenInput(
                  label: '科目名称',
                  controller: _name,
                  enabled: editable,
                  required: true,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ||
                          (value ?? '').trim().length > 240
                      ? '请填写不超过240字的科目名称'
                      : null,
                ),
                const SizedBox(height: 12),
                UtenInput(
                  label: '修改依据',
                  controller: _reference,
                  enabled: editable,
                  required: true,
                  maxLines: 4,
                  validator: (value) =>
                      (value ?? '').trim().isEmpty ||
                          (value ?? '').trim().length > 1000
                      ? '请填写不超过1000字的修改依据'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          if (_sent != null)
            ...financeOriginalRequestActions(
              context,
              busy: _busy,
              receiptLabel: '核对原修改结果',
              receipt: _receipt,
              cancel: _cancelUnwritten,
              onMenuChanged: (value) {
                if (mounted) setState(() => _recoveryMenuOpen = value);
              },
            ),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : _close,
            child: Text(_sent == null ? '关闭' : '稍后核对'),
          ),
          UtenButton(
            onPressed:
                current &&
                    _ready &&
                    !_busy &&
                    (_needsCurrentReview ? _canRead : _canWrite)
                ? (_needsCurrentReview ? _reviewCurrent : _save)
                : null,
            child: Text(
              _sent == null
                  ? (_needsCurrentReview ? '核对当前设置' : '保存名称')
                  : '重试原修改请求',
            ),
          ),
        ],
      ),
    );
  }
}
