import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';

import '../shared/finance_original_command.dart';
import '../../../core/network/api_client.dart';
import '../../../core/performance/json_value_snapshot.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';

/// These are reviewed commands, not a persisted arbitrary HTTP-request queue.
enum FinanceDurableOperation {
  procurementPolicy('PROCUREMENT_AP_POLICY_SAVE', '首次应付设置'),
  reportBinding('GL_REPORT_BINDING_REPLACE', '附表取数设置'),
  reportDefaults('GL_REPORT_BINDINGS_SEED', '按默认名单补齐'),
  inventoryPolicy('INVENTORY_COST_POLICY_SAVE', '对账与启用策略'),
  inventoryPeriod('INVENTORY_COST_PERIOD_CHOICE', '指定入账期间'),
  inventoryPost('INVENTORY_COST_POST', '追加成本凭证'),
  inventoryClose('INVENTORY_COST_CLOSE', '关闭成本期间');

  const FinanceDurableOperation(this.key, this.title);
  final String key, title;
  bool get inventory => index >= inventoryPolicy.index;
  Set<String> get writePermissions => {
    inventory ? Perm.financePostExecute : Perm.paymentStyleEdit,
    if (this == procurementPolicy) ...{
      Perm.supplierSettlementConfirm,
      Perm.financePostExecute,
    },
  };
  Set<String> get readPermissions => {
    Perm.financeReportView,
    if (this == procurementPolicy) ...{
      Perm.arApLedgerView,
      Perm.financeViewAll,
    },
    if (inventory) Perm.goodsCostView,
  };
  String get method => switch (this) {
    procurementPolicy || reportBinding || inventoryPolicy => 'PUT',
    _ => 'POST',
  };
  String path(String target) => switch (this) {
    procurementPolicy => '/finance/procurement-payable-recognitions/policy',
    reportBinding => '/finance/reports/gl/line-bindings/$target',
    reportDefaults => '/finance/reports/gl/line-bindings/defaults',
    inventoryPolicy => '/finance/gl/inventory-cost/policy',
    inventoryPeriod => '/finance/gl/inventory-cost/postings/$target/period',
    inventoryPost => '/finance/gl/inventory-cost/periods/$target/post',
    inventoryClose => '/finance/gl/inventory-cost/periods/$target/close',
  };
  String receiptPath(String requestId) => switch (this) {
    procurementPolicy =>
      '/finance/procurement-payable-recognitions/policy/operations/$requestId',
    reportBinding ||
    reportDefaults => '/finance/reports/gl/line-bindings/operations/$requestId',
    _ => '/finance/gl/inventory-cost/operations/$requestId',
  };
  bool validTarget(String target) => switch (this) {
    reportBinding => RegExp(r'^[A-Z][A-Z0-9_]{0,95}$').hasMatch(target),
    inventoryPeriod => Uuid.isValidUUID(fromString: target),
    inventoryPost || inventoryClose =>
      RegExp(r'^[0-9]{4}-(0[1-9]|1[0-2])$').hasMatch(target) &&
          !target.startsWith('0000'),
    _ => target.isEmpty,
  };
  static FinanceDurableOperation parse(String key) =>
      values.where((value) => value.key == key).firstOrNull ??
      (throw const FormatException('财务草稿的原操作不受支持'));
}

typedef FinanceDurableEditorBuilder =
    Widget Function(BuildContext context, FinanceDurableEditor editor);

class FinanceCommandReview {
  const FinanceCommandReview({
    this.versionPatch = const {},
    required this.rows,
  });
  final Map<String, dynamic> versionPatch;
  final List<(String label, String input, String current)> rows;
}

typedef FinanceCommandReviewLoader =
    Future<FinanceCommandReview> Function(
      ApiClient api,
      Map<String, dynamic> body,
      Map<String, dynamic> source,
      String target,
    );

/// Form-specific fields use this one original-command/durable-draft lifecycle.
/// Endpoint, method and authority always derive from the reviewed operation.
Future<Map<String, dynamic>?> showFinanceDurableCommandDialog(
  BuildContext context, {
  required FinanceDurableOperation operation,
  String target = '',
  Map<String, dynamic>? initialBody,
  Map<String, dynamic> initialContext = const {},
  String? resumeDraftId,
  String? hint,
  String saveLabel = '保存',
  required FinanceDurableEditorBuilder editorBuilder,
  required FinanceCommandReviewLoader reviewLoader,
}) {
  if (!operation.validTarget(target) ||
      initialBody == null && resumeDraftId == null) {
    throw const FormatException('财务命令缺少原目标或原输入');
  }
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FinanceDurableCommandDialog(
      operation: operation,
      target: target,
      initialBody: initialBody,
      initialContext: initialContext,
      resumeDraftId: resumeDraftId,
      hint: hint,
      saveLabel: saveLabel,
      editorBuilder: editorBuilder,
      reviewLoader: reviewLoader,
    ),
  );
}

/// Mutable input facade; immutable sent snapshots live only in the shared owner.
class FinanceDurableEditor {
  FinanceDurableEditor._(this._owner);
  final _FinanceDurableCommandDialogState _owner;
  Map<String, dynamic> get body => Map.unmodifiable(_owner._body);
  Map<String, dynamic> get contextData => Map.unmodifiable(_owner._contextData);
  bool get editable => _owner._editable;
  bool get pending => _owner._sent != null;
  TextEditingController controller(String key) => _owner._controller(key);
  void set(String key, Object? value) => _owner._set(key, value);
}

class _FinanceDurableCommandDialog extends ConsumerStatefulWidget {
  const _FinanceDurableCommandDialog({
    required this.operation,
    required this.target,
    required this.initialBody,
    required this.initialContext,
    required this.resumeDraftId,
    required this.hint,
    required this.saveLabel,
    required this.editorBuilder,
    required this.reviewLoader,
  });
  final FinanceDurableOperation operation;
  final String target;
  final Map<String, dynamic>? initialBody;
  final Map<String, dynamic> initialContext;
  final String? resumeDraftId, hint;
  final String saveLabel;
  final FinanceDurableEditorBuilder editorBuilder;
  final FinanceCommandReviewLoader reviewLoader;
  @override
  ConsumerState<_FinanceDurableCommandDialog> createState() =>
      _FinanceDurableCommandDialogState();
}

class _FinanceDurableCommandDialogState
    extends ConsumerState<_FinanceDurableCommandDialog>
    with FormDraftMixin<_FinanceDurableCommandDialog> {
  final _form = GlobalKey<FormState>();
  final _controllers = <String, TextEditingController>{};
  late Map<String, dynamic> _body = _copy(widget.initialBody ?? {});
  late Map<String, dynamic> _contextData = _copy(widget.initialContext);
  String _requestId = const Uuid().v4();
  Map<String, dynamic>? _sent;
  Map<String, dynamic>? _retiredReceipt;
  bool _needsCurrentReview = false;
  bool _ready = false, _busy = false;
  bool _menuOpen = false;

  String? _error;
  late final _editor = FinanceDurableEditor._(this);
  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(value)) as Map);
  bool get _canRead =>
      ref.read(authenticatedScopeProvider) != null &&
      widget.operation.readPermissions.every(
        ref.read(currentPermissionsProvider).contains,
      );
  bool get _canWrite =>
      financeOriginalIdentityCanMutate(ref.read(authenticatedScopeProvider)) &&
      _canRead &&
      widget.operation.writePermissions.every(
        ref.read(currentPermissionsProvider).contains,
      );
  bool get _editable =>
      _ready &&
      !_busy &&
      _sent == null &&
      _canWrite &&
      formDraftIdentityIsCurrent &&
      !formDraftRestorationBlocked;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeDurableCommand.spec(
        title: widget.operation.title,
        routeParameters: {
          'operation': widget.operation.key,
          if (widget.target.isNotEmpty) 'target': widget.target,
        },
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
  Object formDraftReadBoundaryIdentity(SensitiveReadBoundary boundary) =>
      SensitiveReadBoundary(
        identity: boundary.identity,
        api: boundary.api,
        permissions: {...boundary.permissions}
          ..removeAll(widget.operation.writePermissions),
        superAdmin: boundary.superAdmin,
      );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'schema': 1,
    'operation': widget.operation.key,
    'target': widget.target,
    'requestId': _requestId,
    'body': _copy(_body),
    'context': _copy(_contextData),
    'sent': _sent == null ? null : _copy(_sent!),
    'retiredReceipt': _retiredReceipt == null ? null : _copy(_retiredReceipt!),
    'needsCurrentReview': _needsCurrentReview,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['schema'] != 1 ||
        data['operation'] != widget.operation.key ||
        data['target'] != widget.target ||
        data['requestId'] is! String ||
        !Uuid.isValidUUID(fromString: data['requestId'] as String) ||
        data['body'] is! Map ||
        data['context'] is! Map) {
      throw StateError('原财务命令身份、版本或输入不完整');
    }
    _requestId = data['requestId'] as String;
    _body = _copy(Map<String, dynamic>.from(data['body'] as Map));
    _contextData = _copy(Map<String, dynamic>.from(data['context'] as Map));
    _sent = data['sent'] == null
        ? null
        : _copy(Map<String, dynamic>.from(data['sent'] as Map));
    _retiredReceipt = data['retiredReceipt'] is Map
        ? _copy(Map<String, dynamic>.from(data['retiredReceipt'] as Map))
        : null;
    _needsCurrentReview = data['needsCurrentReview'] == true;
    if (_retiredReceipt != null) {
      final retiredBody = _retiredReceipt!['requestBody'];
      if (retiredBody is! Map ||
          _retiredReceipt!['outcome'] != 'CANCELLED_UNWRITTEN') {
        throw StateError('原请求停止凭据不完整');
      }
      _verifyAgainst(_retiredReceipt!, Map<String, dynamic>.from(retiredBody));
    }
    if (_body.containsKey('requestId') ||
        _sent != null &&
            !jsonValuesEqual(_sent, {..._body, 'requestId': _requestId})) {
      throw StateError('原财务请求与草稿内容不一致，不能重新解释提交');
    }
    for (final entry in _controllers.entries) {
      entry.value.text = _body[entry.key]?.toString() ?? '';
    }
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_canRead) await initializeFormDraft();
      if (mounted) {
        setState(() => _ready = true);
        if (widget.operation == FinanceDurableOperation.reportDefaults &&
            widget.resumeDraftId == null &&
            _sent == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _save();
          });
        }
      }
    });
  }

  TextEditingController _controller(String key) => _controllers.putIfAbsent(
    key,
    () {
      final result = TextEditingController(text: _body[key]?.toString() ?? '');
      result.addListener(() {
        if (!_editable) return;
        _body[key] = result.text;
        markFormDraftChanged();
      });
      return result;
    },
  );
  void _set(String key, Object? value) {
    if (!_editable || key == 'requestId') return;
    setState(() => _body[key] = value);
    markFormDraftChanged();
  }

  Map<String, dynamic> _verify(Map<String, dynamic> envelope) {
    if (_sent == null) throw StateError('缺少原财务命令');
    return _verifyAgainst(envelope, _sent!);
  }

  FinanceOriginalCommand _commandFor(Map<String, dynamic> body) =>
      FinanceOriginalCommand(
        actorId: ref.read(authenticatedScopeProvider)?.userId ?? '',
        operation: widget.operation.key,
        method: widget.operation.method,
        path: widget.operation.path(widget.target),
        body: body,
      );
  Map<String, dynamic> _verifyAgainst(
    Map<String, dynamic> envelope,
    Map<String, dynamic> body,
  ) => _commandFor(body).verify(envelope);
  Future<void> _acceptReceipt(Map<String, dynamic> envelope) async {
    _verify(envelope);
    if (envelope['outcome'] == 'CANCELLED_UNWRITTEN') {
      _retiredReceipt = _copy(envelope);
      _sent = null;
      _needsCurrentReview = true;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (mounted) setState(() {});
      return;
    }
    await completeFormDraft();
    if (mounted) Navigator.pop(context, envelope);
  }

  Future<void> _save() async {
    if (!_ready ||
        _busy ||
        _menuOpen ||
        !_canWrite ||
        _needsCurrentReview ||
        !formDraftIdentityIsCurrent ||
        formDraftRestorationBlocked) {
      return;
    }
    if (_sent == null && _form.currentState?.validate() != true) return;
    final hadPending = _sent != null;
    var dispatched = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_sent == null && _retiredReceipt?['requestId'] == _requestId) {
        _requestId = const Uuid().v4();
      }
      _sent ??= _copy({..._body, 'requestId': _requestId});
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final envelope = await runFormDraftSubmission(
        () => UtenBusyOverlay.run(
          context,
          title: '正在处理${widget.operation.title}',
          action: () => scope.run(() async {
            final api = ref.read(apiClientProvider);
            dispatched = true;
            final response = widget.operation.method == 'PUT'
                ? await api.put(
                    widget.operation.path(widget.target),
                    body: _sent,
                  )
                : await api.post(
                    widget.operation.path(widget.target),
                    body: _sent,
                  );
            _verify(response);
            return response;
          }),
        ),
        isDefiniteRejection: (_) => false,
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptReceipt(envelope);
    } catch (error) {
      if (!dispatched && !hadPending) {
        _sent = null;
        try {
          await releaseFormDraftBeforeDispatch();
        } catch (_) {
          // An older persisted marker is conservative; never infer an outcome
          // from a failed local checkpoint.
        }
      } else {
        try {
          await saveFormDraftNow();
        } catch (_) {}
      }
      if (mounted && formDraftIdentityIsCurrent) {
        setState(
          () => _error = describeSubmitError(
            error,
            fallback: '原操作结果待核对，原内容与请求已保留',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receipt() async {
    if (!_ready ||
        _busy ||
        _sent == null ||
        !_canRead ||
        !formDraftIdentityIsCurrent ||
        formDraftRestorationBlocked) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final response = await UtenBusyOverlay.run(
        context,
        title: '正在核对原${widget.operation.title}',
        action: () => scope.run(
          () => ref
              .read(apiClientProvider)
              .get(widget.operation.receiptPath(_requestId)),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      if (response['found'] != true) {
        setState(() => _error = '尚未取得原成功回执，原内容和请求继续保留。');
        return;
      }
      await _acceptReceipt(response);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(
          () => _error = describeSubmitError(error, fallback: '原操作结果仍待核对'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelUnwritten() async {
    if (!_ready ||
        _busy ||
        _sent == null ||
        !_canRead ||
        !formDraftIdentityIsCurrent ||
        formDraftRestorationBlocked) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final response = await UtenBusyOverlay.run(
        context,
        title: '正在核实原请求是否写入',
        action: () => scope.run(
          () => ref
              .read(apiClientProvider)
              .post(
                '${widget.operation.receiptPath(_requestId)}/cancel',
                body: _commandFor(_sent!).cancellationBody,
              ),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      await _acceptReceipt(response);
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(
          () => _error = describeSubmitError(
            error,
            fallback: '原请求停止结果仍待核对，原内容与请求继续保留',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewCurrent() async {
    if (!_ready ||
        _busy ||
        _sent != null ||
        !_canRead ||
        !formDraftIdentityIsCurrent ||
        formDraftRestorationBlocked) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final review = await UtenBusyOverlay.run(
        context,
        title: '正在读取当前设置',
        action: () => scope.run(
          () => widget.reviewLoader(
            ref.read(apiClientProvider),
            _copy(_body),
            _copy(_contextData),
            widget.target,
          ),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final allowed = switch (widget.operation) {
        FinanceDurableOperation.procurementPolicy => {'expectedRevision'},
        FinanceDurableOperation.reportBinding => {'expectedFingerprint'},
        FinanceDurableOperation.inventoryPolicy ||
        FinanceDurableOperation.inventoryClose => {'expectedVersion'},
        _ => <String>{},
      };
      if (review.versionPatch.keys.any((key) => !allowed.contains(key)) ||
          allowed.any(
            (key) => key == 'expectedFingerprint'
                ? review.versionPatch[key] is! String ||
                      (review.versionPatch[key] as String).isEmpty
                : review.versionPatch[key] is! int ||
                      (review.versionPatch[key] as int) < 0,
          )) {
        throw StateError('当前版本依据不完整，原输入继续保留');
      }
      final accepted = await showFinanceCurrentVersionReview(
        context,
        rows: review.rows,
      );
      if (accepted != true ||
          !mounted ||
          !scope.isCurrent ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      _body.addAll(review.versionPatch);
      _needsCurrentReview = false;
      await saveFormDraftNow();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(
          () => _error = describeSubmitError(
            error,
            fallback: '当前设置未核对完成，原输入继续保留',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy || _menuOpen) return;
    if (_sent != null && formDraftHasUnknownSubmission) {
      setState(() => _busy = true);
      try {
        await saveFormDraftNow();
        if (mounted && formDraftIdentityIsCurrent) Navigator.pop(context);
      } catch (error) {
        if (mounted) setState(() => _error = describeFormSaveError(error));
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    if (!_busy && await confirmFormDraftExit() && mounted) {
      Navigator.pop(context);
    }
  }

  @override
  void dispose() {
    for (final value in _controllers.values) {
      value.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    if (!formDraftIdentityIsCurrent || !_canRead) {
      return UtenAlertDialog(
        title: const Text('访问范围已变化'),
        content: const Text('原财务草稿与未决请求已保留，请以具备原读取权限的账号重新打开。'),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      );
    }
    return withFormDraft(
      UtenAlertDialog(
        key: const Key('finance-durable-command'),
        maxWidth: 760,
        title: UtenDialogTitleWithHint(
          title: Text(widget.operation.title),
          info: _sent == null
              ? (_needsCurrentReview
                    ? '原输入已保留。请先核对当前设置；采用当前版本后，由你点击保存新请求。'
                    : widget.hint)
              : '原请求结果待核对；保留原账号、目标、版本和内容，不按当前配置相同推定成功，不更换请求编号重放。',
        ),
        content: !_ready
            ? const SizedBox(
                height: 80,
                child: UtenBusyOverlay(title: '正在恢复原财务输入'),
              )
            : Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    widget.editorBuilder(context, _editor),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
        actions: [
          if (_sent != null)
            ...financeOriginalRequestActions(
              context,
              busy: _busy,
              receiptLabel: '核对原操作结果',
              receipt: _receipt,
              cancel: _cancelUnwritten,
              onMenuChanged: (value) {
                if (mounted) setState(() => _menuOpen = value);
              },
            ),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : _close,
            child: Text(_sent == null ? '取消' : '稍后核对'),
          ),
          UtenButton(
            key: widget.operation.inventory
                ? const ValueKey('inventory-cost-confirm')
                : widget.operation == FinanceDurableOperation.reportBinding
                ? const ValueKey('gl-line-target-save')
                : const ValueKey('finance-command-save'),
            onPressed:
                _ready &&
                    !_busy &&
                    (_needsCurrentReview ? _canRead : _canWrite) &&
                    !formDraftRestorationBlocked
                ? (_needsCurrentReview ? _reviewCurrent : _save)
                : null,
            child: Text(
              _sent == null
                  ? (_needsCurrentReview ? '核对当前设置' : widget.saveLabel)
                  : '重试原请求',
            ),
          ),
        ],
      ),
    );
  }
}
