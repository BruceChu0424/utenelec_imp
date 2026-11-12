import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_client.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/drafts/form_draft_dialog_resume.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../shared/finance_original_command.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import 'finance_applications_page.dart';

class FinanceApplicationSettingsPage extends ConsumerStatefulWidget {
  const FinanceApplicationSettingsPage({super.key});
  @override
  ConsumerState<FinanceApplicationSettingsPage> createState() =>
      _SettingsState();
}

class _SettingsState extends ConsumerState<FinanceApplicationSettingsPage>
    with ReadViewActivityMixin<FinanceApplicationSettingsPage> {
  Map<String, dynamic> _data = {}, _refs = {};
  String? _error;
  bool _busy = true;
  bool _editing = false;
  int _epoch = -1, _request = 0;
  int _acceptedEpoch = -1;
  ApiClient? _acceptedApi;
  @override
  void initState() {
    super.initState();
    ref.listenManual(exportContextEpochProvider, (previous, next) {
      if (!mounted || previous == next) return;
      ++_request;
      setState(() {
        _busy = false;
        _data = {};
        _refs = {};
        _acceptedEpoch = -1;
        _acceptedApi = null;
        _error = '身份、权限或服务器已变化，请刷新流程设置';
      });
    });
    unawaited(_load());
  }

  @override
  Future<void> onReadViewResumed() => _load();

  Future<void> _load() async {
    if (!mounted) return;
    final api = ref.read(apiClientProvider);
    final epoch = ref.read(exportContextEpochProvider), request = ++_request;
    final retainAccepted =
        _acceptedEpoch == epoch && identical(_acceptedApi, api);
    bool current() =>
        mounted &&
        request == _request &&
        epoch == ref.read(exportContextEpochProvider) &&
        identical(api, ref.read(apiClientProvider));
    setState(() {
      _busy = true;
      _error = null;
      _epoch = epoch;
      if (!retainAccepted) {
        _data = {};
        _refs = {};
        _acceptedEpoch = -1;
        _acceptedApi = null;
      }
    });
    try {
      final rows = await readViewActivity.runRead(
        current,
        () => Future.wait([
          api.get('$financeApplicationsApi/settings'),
          api.get('$financeApplicationsApi/references'),
        ], eagerError: true),
      );
      if (!current()) return;
      setState(() {
        _data = rows[0];
        _refs = rows[1];
        _acceptedEpoch = epoch;
        _acceptedApi = api;
      });
    } catch (error) {
      if (current()) {
        setState(
          () => _error = isRetiredViewRead(error)
              ? '读取已中断，请刷新流程设置'
              : humanErrorMessage(error) ?? '流程设置未读取完成，请重试',
        );
      }
    } finally {
      // A retired response may release only its own read wait, never a newer
      // request or a durable editor/unknown command. Epoch listeners already
      // retire old rows and release that old wait immediately.
      if (mounted && request == _request) setState(() => _busy = false);
    }
  }

  Future<void> _edit({
    Map<String, dynamic>? role,
    bool settings = false,
    String? resumeDraftId,
  }) async {
    if (_editing ||
        _busy ||
        _acceptedEpoch != _epoch ||
        _acceptedApi == null ||
        _epoch != ref.read(exportContextEpochProvider) ||
        !identical(_acceptedApi, ref.read(apiClientProvider))) {
      return;
    }
    _editing = true;
    try {
      final epoch = _epoch;
      final updated = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _SettingsEditor(
          data: _data,
          references: _refs,
          role: role,
          settings: settings,
          resumeDraftId: resumeDraftId,
        ),
      );
      if (updated == true &&
          mounted &&
          epoch == ref.read(exportContextEpochProvider)) {
        await _load();
      }
    } finally {
      _editing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final current =
        ref.watch(exportContextEpochProvider) == _acceptedEpoch &&
        _acceptedApi != null &&
        identical(_acceptedApi, ref.read(apiClientProvider));
    final rows = current
        ? financeApplicationRows(_data['roles'])
        : <Map<String, dynamic>>[];
    final definitions = {
      for (final r in financeApplicationRows(_data['roleDefinitions']))
        r['key']: r['label'],
    };
    return FormDraftDialogResume(
      descriptor: FormDraftCatalog.financeApplicationSettings,
      ready: current && !_busy,
      onResume: (parameters) async {
        final settings = parameters['settings'];
        if (!const {'true', 'false'}.contains(settings)) {
          throw const FormatException('流程设置草稿缺少原操作类型');
        }
        final roleId = parameters['roleId'];
        if (settings == 'false' &&
            (roleId == null || !Uuid.isValidUUID(fromString: roleId))) {
          throw const FormatException('岗位草稿缺少原配置编号');
        }
        await _edit(
          settings: settings == 'true',
          role: settings == 'false' ? {'id': roleId} : null,
          resumeDraftId: parameters['draftId'],
        );
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: '各部门申请流程 · 流程设置',
          showBackButton: true,
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : _load,
              child: const Text('刷新'),
            ),
          ],
        ),
        body: UtenContentContainer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    UtenDialogTitleWithHint(
                      title: Text(
                        !current
                            ? '流程资料需重新读取'
                            : _data['enabled'] == true
                            ? '新申请流程已启用'
                            : '新申请流程未启用',
                      ),
                      info:
                          '原图人名是岗位说明；请选择真实在职员工及其启用账号。启用后只接新申请，历史已审批单不退回重审。部门负责人优先使用明确代理配置，否则沿组织架构负责人。',
                    ),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: current && !_busy
                          ? () => _edit(settings: true)
                          : null,
                      child: const Text('启用/关闭'),
                    ),
                    UtenButton(
                      onPressed: current && !_busy
                          ? () => _edit(role: {})
                          : null,
                      child: const Text('新增岗位人员'),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: MasterDataTableView<Map<String, dynamic>>(
                  columns: [
                    MasterColumnDef(
                      key: 'roleKey',
                      label: '原流程岗位',
                      width: 250,
                      // 类别列：按当前行值出选项筛选（2026-11-11 口径）。
                      filterFromRows: true,
                      value: (r) => definitions[r['roleKey']]?.toString() ?? '',
                      columnSearchEnabled: false,
                    ),
                    financeApplicationColumn('departmentName', '部门', 170),
                    financeApplicationColumn('employeeName', '实际办理人员', 180),
                    financeApplicationColumn('sourceReference', '指派依据', 320),
                  ],
                  items: rows,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  isLoading: _busy,
                  error: _error,
                  onRetry: _load,
                  onRowTap: (r) => _edit(role: r),
                  showPaginationControls: false,
                  headerFilterScopeDescription: '本页原流程全部岗位配置，点击一行编辑',
                  rowKeyOf: (r) => r['id'].toString(),
                ),
              ),
              if (_busy)
                const UtenBusyOverlay(
                  title: '正在读取申请流程设置',
                  showDoNotLeaveHint: false,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsEditor extends ConsumerStatefulWidget {
  const _SettingsEditor({
    required this.data,
    required this.references,
    this.role,
    required this.settings,
    this.resumeDraftId,
  });
  final Map<String, dynamic> data, references;
  final Map<String, dynamic>? role;
  final bool settings;
  final String? resumeDraftId;
  @override
  ConsumerState<_SettingsEditor> createState() => _SettingsEditorState();
}

class _SettingsEditorState extends ConsumerState<_SettingsEditor>
    with FormDraftMixin<_SettingsEditor> {
  final _reference = TextEditingController();
  String? _role, _department, _employee;
  bool _enabled = false, _busy = false;
  late String _id;
  String _requestId = const Uuid().v4();
  late int _expectedVersion;
  bool _ready = false;
  Map<String, dynamic>? _sent;
  Map<String, dynamic>? _retiredReceipt;
  bool _needsCurrentReview = false,
      _recoveryMenuOpen = false,
      _confirming = false;
  bool _hadExistingRole = false;
  String _pendingAction = 'SAVE', _employeeLabel = '';
  bool get _canAccess =>
      ref.read(authenticatedScopeProvider) != null &&
      ref.read(currentPermissionsProvider).contains(Perm.expenseSettings);
  bool get _canMutate =>
      _canAccess &&
      financeOriginalIdentityCanMutate(ref.read(authenticatedScopeProvider));
  String get _operation => widget.settings
      ? 'SETTINGS_SAVE'
      : _pendingAction == 'REMOVE'
      ? 'ROLE_REMOVE'
      : 'ROLE_SAVE';
  String get _method => _operation == 'ROLE_REMOVE' ? 'DELETE' : 'POST';
  String get _path =>
      '$financeApplicationsApi/settings${widget.settings
          ? ''
          : _pendingAction == 'REMOVE'
          ? '/roles/$_id'
          : '/roles'}';
  String get _receiptPath =>
      '$financeApplicationsApi/settings/operations/$_requestId';
  FinanceOriginalCommand _command(Map<String, dynamic> body) =>
      FinanceOriginalCommand(
        actorId: ref.read(authenticatedScopeProvider)?.userId ?? '',
        operation: _operation,
        method: _method,
        path: _path,
        body: body,
      );
  late int _epoch;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.financeApplicationSettings.spec(
        routeParameters: {
          'settings': widget.settings.toString(),
          if (!widget.settings) 'roleId': _id,
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
  Iterable<Listenable> get formDraftListenables => [_reference];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'settings': widget.settings,
    'id': _id,
    'requestId': _requestId,
    'expectedVersion': _expectedVersion,
    'role': _role,
    'department': _department,
    'employee': _employee,
    'enabled': _enabled,
    'reference': _reference.text,
    'sent': _sent,
    'pendingAction': _pendingAction,
    'hadExistingRole': _hadExistingRole,
    'employeeLabel': _employeeLabel,
    'requestRecovery': {
      'retiredReceipt': _retiredReceipt,
      'needsCurrentReview': _needsCurrentReview,
    },
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['settings'] != widget.settings ||
        (!widget.settings && data['id'] != _id)) {
      throw StateError('流程设置草稿的操作或原岗位编号不一致');
    }
    final requestId = data['requestId'], version = data['expectedVersion'];
    if (requestId is! String ||
        !Uuid.isValidUUID(fromString: requestId) ||
        version is! int ||
        version < -1) {
      throw StateError('原请求编号或原设置版本不完整');
    }
    _requestId = requestId;
    final savedId = data['id'];
    if (savedId is! String || !Uuid.isValidUUID(fromString: savedId)) {
      throw StateError('流程设置草稿缺少原记录编号');
    }
    _id = savedId;
    _expectedVersion = version;
    _pendingAction = data['pendingAction']?.toString() ?? 'SAVE';
    if (!const {'SAVE', 'REMOVE'}.contains(_pendingAction) ||
        widget.settings && _pendingAction != 'SAVE') {
      throw StateError('原流程设置操作不受支持');
    }
    _hadExistingRole =
        data['hadExistingRole'] == true || !widget.settings && version >= 0;
    _employeeLabel = data['employeeLabel']?.toString() ?? '';
    _role = data['role'] as String?;
    _department = data['department'] as String?;
    _employee = data['employee'] as String?;
    _enabled = data['enabled'] == true;
    _reference.text = data['reference']?.toString() ?? '';
    _sent = data['sent'] is Map
        ? Map<String, dynamic>.from(data['sent'] as Map)
        : null;
    if (_sent != null) {
      final expected = _payload();
      if (_sent!.length != expected.length ||
          expected.entries.any((entry) => _sent![entry.key] != entry.value)) {
        throw StateError('原请求参数与流程设置草稿不一致');
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
      final operation = _retiredReceipt!['operation'];
      if (body is! Map ||
          _retiredReceipt!['outcome'] != 'CANCELLED_UNWRITTEN' ||
          (widget.settings
              ? operation != 'SETTINGS_SAVE'
              : !const {'ROLE_SAVE', 'ROLE_REMOVE'}.contains(operation)) ||
          !widget.settings && body['id'] != _id) {
        throw StateError('原岗位配置请求停止证明不完整');
      }
      FinanceOriginalCommand(
        actorId: ref.read(authenticatedScopeProvider)?.userId ?? '',
        operation: operation.toString(),
        method: operation == 'ROLE_REMOVE' ? 'DELETE' : 'POST',
        path:
            '$financeApplicationsApi/settings${widget.settings
                ? ''
                : operation == 'ROLE_REMOVE'
                ? '/roles/$_id'
                : '/roles'}',
        body: Map<String, dynamic>.from(body),
      ).verify(_retiredReceipt!);
    }
  }

  @override
  void initState() {
    super.initState();
    _epoch = ref.read(exportContextEpochProvider);
    _id = widget.role?['id']?.toString() ?? const Uuid().v4();
    _expectedVersion =
        (widget.settings ? widget.data['version'] : widget.role?['version'])
            as int? ??
        -1;
    _hadExistingRole = !widget.settings && _expectedVersion >= 0;
    _employeeLabel = widget.role?['employeeName']?.toString() ?? '';
    _role = widget.role?['roleKey']?.toString();
    _department = widget.role?['departmentId']?.toString();
    _employee = widget.role?['employeeId']?.toString();
    _reference.text =
        (widget.settings
                ? widget.data['sourceReference']
                : widget.role?['sourceReference'])
            ?.toString() ??
        '';
    _enabled = widget.data['enabled'] == true;
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (mounted) setState(() => _ready = true);
    });
  }

  Map<String, dynamic> _payload() =>
      !widget.settings && _pendingAction == 'REMOVE'
      ? {
          'requestId': _requestId,
          'id': _id,
          'expectedVersion': _expectedVersion,
        }
      : widget.settings
      ? {
          'expectedVersion': _expectedVersion,
          'requestId': _requestId,
          'enabled': _enabled,
          'sourceReference': _reference.text,
        }
      : {
          'id': _id,
          'requestId': _requestId,
          'expectedVersion': _expectedVersion,
          'roleKey': _role,
          'departmentId': _role == 'DEPARTMENT_REVIEW' ? _department : null,
          'employeeId': _employee,
          'sourceReference': _reference.text,
        };

  Future<void> _save({bool remove = false}) async {
    if (!_ready ||
        _busy ||
        _recoveryMenuOpen ||
        _confirming ||
        _needsCurrentReview ||
        !_canMutate ||
        !formDraftIdentityIsCurrent ||
        _epoch != ref.read(exportContextEpochProvider)) {
      return;
    }
    if (_sent == null &&
        !remove &&
        (_reference.text.trim().isEmpty ||
            !widget.settings &&
                (_role == null ||
                    _employee == null ||
                    _role == 'DEPARTMENT_REVIEW' && _department == null))) {
      context.appWarning('请填写实际岗位人员、适用部门和配置依据');
      return;
    }
    final hadPending = _sent != null;
    var dispatched = false;
    setState(() => _busy = true);
    try {
      if (_sent == null) {
        _pendingAction = remove ? 'REMOVE' : 'SAVE';
        if (_retiredReceipt?['requestId'] == _requestId) {
          _requestId = const Uuid().v4();
        }
      }
      _sent ??= _payload();
      final scope = await captureFormDraftRequestScope();
      final receipt = await runFormDraftSubmission(
        () => UtenBusyOverlay.run(
          context,
          title: '正在保存申请流程设置',
          action: () => scope.run(() async {
            final api = ref.read(apiClientProvider);
            dispatched = true;
            if (_pendingAction == 'REMOVE') {
              await api.delete(
                _path,
                query: {
                  'expectedVersion': _sent!['expectedVersion'],
                  'requestId': _requestId,
                },
              );
            } else {
              await api.post(_path, body: _sent);
            }
            if (!scope.isCurrent || !formDraftIdentityIsCurrent) {
              throw StateError('原流程设置身份已变化');
            }
            return _command(_sent!).readReceipt(api, _receiptPath);
          }),
        ),
        isDefiniteRejection: (_) => false,
      );
      if (mounted &&
          scope.isCurrent &&
          formDraftIdentityIsCurrent &&
          _epoch == ref.read(exportContextEpochProvider)) {
        await _acceptReceipt(receipt);
      }
    } catch (e) {
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
      if (mounted && _epoch == ref.read(exportContextEpochProvider)) {
        context.appApiError(e, fallback: '设置结果待确认，请保留原内容并重试');
      }
    } finally {
      if (mounted && _epoch == ref.read(exportContextEpochProvider)) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _acceptReceipt(Map<String, dynamic> receipt) async {
    if (receipt['found'] != true) {
      context.appWarning('尚未取得原设置回执，原参数与请求继续保留。');
      return;
    }
    _command(_sent!).verify(receipt);
    if (receipt['outcome'] == 'CANCELLED_UNWRITTEN') {
      _retiredReceipt = Map<String, dynamic>.from(receipt);
      _sent = null;
      _pendingAction = 'SAVE';
      _needsCurrentReview = true;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (mounted) setState(() {});
      return;
    }
    if (receipt['result'] is! Map) throw StateError('原设置成功回执不完整');
    await completeFormDraft();
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _cancelUnwritten() async {
    if (_busy || _sent == null || !_canAccess || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final receipt = await UtenBusyOverlay.run(
        context,
        title: '正在核实原设置请求',
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
        context.appApiError(error, fallback: '停止结果仍待核对，原设置请求继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reviewCurrent() async {
    if (_busy || _sent != null || !_canAccess || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final current = await UtenBusyOverlay.run(
        context,
        title: '正在读取当前流程配置',
        action: () => scope.run(
          () => ref
              .read(apiClientProvider)
              .get('$financeApplicationsApi/settings'),
        ),
      );
      if (!mounted || !scope.isCurrent || !formDraftIdentityIsCurrent) return;
      final currentRole = widget.settings
          ? null
          : financeApplicationRows(
              current['roles'],
            ).where((row) => row['id'] == _id).firstOrNull;
      if (!widget.settings && currentRole == null && _hadExistingRole) {
        throw StateError('原岗位配置当前已不存在，请保留输入并在配置列表核对，不能按新记录重建原身份');
      }
      final version = widget.settings
          ? current['version']
          : currentRole?['version'] ?? -1;
      if (version is! int || version < (widget.settings ? 0 : -1)) {
        throw StateError('当前配置缺少版本依据');
      }
      final definitions = {
        for (final row in financeApplicationRows(current['roleDefinitions']))
          row['key']: row['label']?.toString() ?? '',
      };
      final departments = {
        for (final row in financeApplicationRows(
          widget.references['departments'],
        ))
          row['id']: row['name']?.toString() ?? '',
      };
      final adopted = await showFinanceCurrentVersionReview(
        context,
        rows: widget.settings
            ? [
                (
                  '新申请流程',
                  _enabled ? '启用' : '关闭新申请接入',
                  current['enabled'] == true ? '启用' : '关闭新申请接入',
                ),
                (
                  '启用/关闭依据',
                  _reference.text,
                  '${current['sourceReference'] ?? ''}',
                ),
              ]
            : [
                (
                  '原流程岗位',
                  definitions[_role] ?? '原已选岗位',
                  currentRole == null
                      ? '尚无该配置'
                      : definitions[currentRole['roleKey']] ??
                            '${currentRole['roleKey']}',
                ),
                (
                  '实际办理人员',
                  _employeeLabel.isNotEmpty
                      ? _employeeLabel
                      : _employee == null
                      ? '未选择'
                      : '原已选人员',
                  '${currentRole?['employeeName'] ?? '尚无该配置'}',
                ),
                (
                  '明确部门',
                  departments[_department] ?? '未指定',
                  '${currentRole?['departmentName'] ?? '未指定'}',
                ),
                (
                  '指派依据',
                  _reference.text,
                  '${currentRole?['sourceReference'] ?? '尚无该配置'}',
                ),
              ],
      );
      if (!adopted ||
          !mounted ||
          !scope.isCurrent ||
          !formDraftIdentityIsCurrent) {
        return;
      }
      _expectedVersion = version;
      _hadExistingRole = _hadExistingRole || currentRole != null;
      _needsCurrentReview = false;
      await saveFormDraftNow();
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        context.appApiError(error, fallback: '当前配置尚未核对完成，原输入继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    if (_busy ||
        _confirming ||
        _recoveryMenuOpen ||
        _sent != null ||
        _needsCurrentReview ||
        widget.settings ||
        !_hadExistingRole ||
        _expectedVersion < 0 ||
        !_canAccess ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _confirming = true);
    var accepted = false;
    try {
      accepted =
          await showDialog<bool>(
            context: context,
            builder: (dialogContext) => UtenAlertDialog(
              title: const UtenDialogTitleWithHint(
                title: Text('移除岗位人员'),
                info: '只移除当前人员配置；历史审批事实保留。本窗口尚未保存的人员修改不会提交。',
              ),
              content: SelectableText(
                '当前配置人员：${widget.role?['employeeName'] ?? _employeeLabel}',
              ),
              actions: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('返回配置'),
                ),
                UtenButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('确认移除'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (accepted && mounted) await _save(remove: true);
  }

  Future<void> _close() async {
    if (_busy || _recoveryMenuOpen || _confirming) return;
    if (_sent != null) {
      try {
        if (!await saveFormDraftBeforeExit()) return;
        if (mounted && formDraftIdentityIsCurrent) Navigator.pop(context);
      } catch (error) {
        if (mounted) context.appApiError(error, fallback: '原设置请求尚未保存，请保留当前窗口');
      }
      return;
    }
    if (await confirmFormDraftExit() && mounted) Navigator.pop(context);
  }

  Future<void> _receipt() async {
    if (_busy || _sent == null || !_canAccess || !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() => _busy = true);
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final receipt = await UtenBusyOverlay.run(
        context,
        title: '正在核对原设置结果',
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
        context.appApiError(error, fallback: '原请求结果仍待核对，原参数继续保留');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    if (!_canAccess || !formDraftIdentityIsCurrent) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),
        title: const Text('访问范围已变化'),
        content: const Text('原设置草稿与请求保留在原账号下，恢复权限后可继续核对。'),
      );
    }
    final current = ref.watch(exportContextEpochProvider) == _epoch;
    final editable =
        _canMutate &&
        current &&
        formDraftIdentityIsCurrent &&
        _ready &&
        !_busy &&
        _sent == null;
    return withFormDraft(
      UtenAlertDialog(
        showCloseButton: true,
        onClose: _close,
        closeEnabled: !_busy,
        closeTooltip: _sent == null ? '关闭' : '稍后核对',
        title: UtenDialogTitleWithHint(
          title: Text(widget.settings ? '启用/关闭原申请流程' : '明确配置原岗位人员'),
          info: _needsCurrentReview
              ? '原请求已停止，原输入已保留。先核对当前配置并采用当前版本，再由你点击保存新请求。'
              : _sent != null
              ? '原请求结果待核对，保留原账号、配置编号、版本和输入。'
              : null,
        ),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.settings)
                  UtenDropdownField(
                    label: '新申请流程',
                    value: _enabled ? 'on' : 'off',
                    items: const [
                      UtenDropdownItem(value: 'on', label: '启用'),
                      UtenDropdownItem(value: 'off', label: '关闭新申请接入'),
                    ],
                    enabled: editable,
                    allowClear: false,
                    onChanged: editable
                        ? (v) {
                            setState(() => _enabled = v == 'on');
                            markFormDraftChanged();
                          }
                        : (_) {},
                  )
                else ...[
                  UtenDropdownField(
                    label: '原流程岗位',
                    value: _role,
                    items: [
                      for (final r in financeApplicationRows(
                        widget.data['roleDefinitions'],
                      ))
                        UtenDropdownItem(
                          value: r['key'].toString(),
                          label: r['label'].toString(),
                        ),
                    ],
                    enabled: editable,
                    onChanged: editable
                        ? (v) {
                            setState(() => _role = v);
                            markFormDraftChanged();
                          }
                        : (_) {},
                  ),
                  const SizedBox(height: 12),
                  if (_role == 'DEPARTMENT_REVIEW')
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: UtenDropdownField(
                        label: '明确部门',
                        value: _department,
                        items: [
                          for (final r in financeApplicationRows(
                            widget.references['departments'],
                          ))
                            UtenDropdownItem(
                              value: r['id'].toString(),
                              label: r['name'].toString(),
                            ),
                        ],
                        enabled: editable,
                        onChanged: editable
                            ? (v) {
                                setState(() => _department = v);
                                markFormDraftChanged();
                              }
                            : (_) {},
                      ),
                    ),
                  BusinessEmployeePicker(
                    purpose:
                        EmployeeReferencePurpose.financeApplicationReviewer,
                    selectedId: _employee,
                    label: '实际办理人员',
                    statuses: const {'active', 'probation', 'onLeave'},
                    enabled: editable,
                    required: true,
                    onChanged: (v) {
                      setState(() {
                        _employee = v?.id;
                        _employeeLabel = v == null ? '' : v.displayName;
                      });
                      markFormDraftChanged();
                    },
                  ),
                ],
                const SizedBox(height: 12),
                UtenInput(
                  label: widget.settings ? '启用/关闭依据' : '指派依据',
                  controller: _reference,
                  enabled: editable,
                  maxLines: 3,
                  required: true,
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
              receiptLabel: '核对原设置结果',
              receipt: _receipt,
              cancel: _cancelUnwritten,
              onMenuChanged: (value) {
                if (mounted) setState(() => _recoveryMenuOpen = value);
              },
            ),
          if (_sent == null && !widget.settings && _hadExistingRole)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: !_busy && _canMutate && !_needsCurrentReview
                  ? _remove
                  : null,
              child: const Text('移除岗位人员'),
            ),

          UtenButton(
            onPressed:
                current &&
                    _ready &&
                    !_busy &&
                    !_confirming &&
                    (_needsCurrentReview || _canMutate)
                ? (_needsCurrentReview ? _reviewCurrent : _save)
                : null,
            child: Text(
              _sent == null
                  ? (_needsCurrentReview ? '核对当前设置' : '保存')
                  : _pendingAction == 'REMOVE'
                  ? '重试原移除请求'
                  : '重试原设置',
            ),
          ),
        ],
      ),
    );
  }
}
