import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/client_access_models.dart';
import '../repositories/client_repository.dart';
import 'client_access_employee_loader.dart';
import 'master_edit_owner.dart';

typedef ClientAccessLoader =
    Future<ClientAccessSettings> Function(String clientId);
typedef ClientAccessSaver =
    Future<ClientAccessSettings> Function(
      String clientId,
      ClientAccessUpdate update,
    );

/// 打开单客户“负责人和可见人”设置。
///
/// 调用方提供 loader/saver，面板只负责清晰的交互与并发反馈，避免把 API
/// 细节耦合到通用自适应面板中。
Future<ClientAccessSettings?> showClientAccessPanel({
  required BuildContext context,
  required WidgetRef ref,
  required String clientId,
  required String clientName,
  required ClientAccessLoader loader,
  required ClientAccessSaver saver,
}) async {
  final owner = MasterEditOwner(
    context,
    ref,
    permissions: {Perm.clientView, Perm.clientAssign},
  );
  try {
    if (!await owner.bindRequests() || !context.mounted) return null;
    final result = await showUtenAdaptivePanel<ClientAccessSettings>(
      context: context,
      drawerWidth: 480,
      widthFraction: UtenPanelWidth.content,
      showDragHandle: true,
      builder: (panelContext) => owner.ownDialog(
        panelContext,
        ClientAccessPanel(
          clientId: clientId,
          clientName: clientName,
          loader: loader,
          saver: saver,
          submissionOwner: owner,
        ),
      ),
    );
    return owner.isCurrent ? result : null;
  } finally {
    owner.dispose();
  }
}

class ClientAccessPanel extends ConsumerStatefulWidget {
  const ClientAccessPanel({
    super.key,
    required this.clientId,
    required this.clientName,
    required this.loader,
    required this.saver,
    this.submissionOwner,
  });

  final String clientId;
  final String clientName;
  final ClientAccessLoader loader;
  final ClientAccessSaver saver;
  final MasterEditOwner? submissionOwner;

  @override
  ConsumerState<ClientAccessPanel> createState() => _ClientAccessPanelState();
}

class _ClientAccessPanelState extends ConsumerState<ClientAccessPanel> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _confirming = false;
  String? _loadError;
  int _accessVersion = 0;

  List<UtenEmployeePickerItem> _owners = const [];
  List<UtenEmployeePickerItem> _viewers = const [];
  List<String> _initialOwnerIds = const [];
  Set<String> _initialViewerIds = const {};

  bool get _dirty {
    final currentViewerIds = _viewers.map((item) => item.id).toSet();
    return !_sameOrderedIds(
          _owners.map((item) => item.id).toList(growable: false),
          _initialOwnerIds,
        ) ||
        !_sameIds(currentViewerIds, _initialViewerIds);
  }

  bool get _isCurrent => mounted && widget.submissionOwner?.isCurrent != false;

  Future<T> _run<T>(Future<T> Function() action) =>
      widget.submissionOwner?.run(action) ?? action();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted || !_isCurrent) return;
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final settings = await _run(() => widget.loader(widget.clientId));
      if (!mounted || !_isCurrent) return;
      _apply(settings);
      _reasonController.clear();
    } on ApiException catch (error) {
      if (!mounted || !_isCurrent) return;
      setState(() => _loadError = error.message);
    } catch (_) {
      if (!_isCurrent) return;
      setState(() => _loadError = '客户访问设置加载失败，请重试');
    } finally {
      if (_isCurrent) setState(() => _loading = false);
    }
  }

  void _apply(ClientAccessSettings settings) {
    UtenEmployeePickerItem item(ClientAccessViewer person) =>
        UtenEmployeePickerItem(
          id: person.employeeId,
          name: person.name,
          employeeCode: person.code,
          departmentName: person.departmentName,
        );
    final owners = settings.effectiveOwners.map(item).toList(growable: false);
    final ownerIds = owners.map((owner) => owner.id).toSet();
    final viewers = settings.viewers
        .where((viewer) => !ownerIds.contains(viewer.employeeId))
        .map(item)
        .toList(growable: false);
    setState(() {
      _accessVersion = settings.accessVersion;
      _owners = owners;
      _viewers = viewers;
      _initialOwnerIds = owners
          .map((owner) => owner.id)
          .toList(growable: false);
      _initialViewerIds = viewers.map((person) => person.id).toSet();
    });
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(
    String? keyword, {
    bool excludeOwner = false,
  }) async {
    final employees = await _run(
      () => loadClientAccessEmployees(
        ref.read(clientRepositoryProvider),
        keyword,
      ),
    );
    return excludeOwner
        ? employees
              .where(
                (employee) => !_owners.any((owner) => owner.id == employee.id),
              )
              .toList(growable: false)
        : employees;
  }

  void _changeOwners(List<UtenEmployeePickerItem> next) {
    final ownerIds = next.map((owner) => owner.id).toSet();
    setState(() {
      _owners = next;
      _viewers = _viewers
          .where((viewer) => !ownerIds.contains(viewer.id))
          .toList(growable: false);
    });
  }

  Future<void> _save() async {
    if (_saving || _confirming || !_dirty || !_isCurrent) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_owners.isEmpty) return;
    final ownerIds = _owners.map((owner) => owner.id).toList(growable: false);
    final reason = _reasonController.text.trim();
    final viewerIds =
        _viewers
            .map((viewer) => viewer.id)
            .where((id) => !ownerIds.contains(id))
            .toSet()
            .toList()
          ..sort();
    setState(() => _confirming = true);
    final confirmed = await UtenDialog.show(
      context,
      title: '确认保存客户访问设置？',
      content: Text(
        '客户：${widget.clientName}\n'
        '负责人：${_owners.map((owner) => owner.name).join('、')}\n'
        '额外只读查看人：${viewerIds.length} 人\n\n'
        '本次修改不会改写历史制单、审批或审计记录。'
        '${_initialOwnerIds.toSet().difference(ownerIds.toSet()).isNotEmpty ? '\n\n移出的原负责人如仍在职且账号启用，系统会暂时保留其只读查看权以完成在途单据；最终以保存回执为准。' : ''}',
      ),
      confirmLabel: '确认保存',
      scopeBuilder: widget.submissionOwner?.ownDialog,
    );
    if (!_isCurrent) return;
    setState(() => _confirming = false);
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final saved = await _run(
        () => widget.saver(
          widget.clientId,
          ClientAccessUpdate(
            ownerEmployeeId: ownerIds.first,
            ownerEmployeeIds: ownerIds,
            viewerEmployeeIds: viewerIds,
            expectedAccessVersion: _accessVersion,
            reason: reason,
          ),
        ),
      );
      if (!mounted || !_isCurrent) return;
      context.appSuccess('负责人和可见人已保存；当前额外查看 ${saved.viewers.length} 人');
      Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted || !_isCurrent) return;
      if (error.code == 'CONFLICT') {
        context.appError('设置已被其他人更新，已为你刷新最新数据');
        await _load();
      } else {
        context.appApiError(error);
      }
    } catch (_) {
      if (mounted && _isCurrent) context.appError('保存失败，请稍后重试');
    } finally {
      if (_isCurrent) setState(() => _saving = false);
    }
  }

  Future<void> _cancel() async {
    if (_saving || _confirming || !_isCurrent) return;
    if (_dirty) {
      setState(() => _confirming = true);
      final discard = await UtenDialog.show(
        context,
        title: '放弃未保存修改？',
        content: const Text('负责人或额外可见人已经修改，离开后不会保存。'),
        confirmLabel: '放弃修改',
        danger: true,
        scopeBuilder: widget.submissionOwner?.ownDialog,
      );
      if (!mounted || !_isCurrent) return;
      setState(() => _confirming = false);
      if (discard != true) return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<void>(
      canPop: !_dirty && !_saving && !_confirming,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: Column(
        key: const ValueKey('client-access-panel'),
        children: [
          // 保存可见人设置网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
          if (_saving)
            const UtenBusyOverlay(
              title: '正在保存负责人和可见人',
              description: '正在写入客户访问设置，请勿重复提交或关闭面板。',
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s16,
              UtenSpacing.s8,
              UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '负责人和可见人',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.clientName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: _saving ? null : _cancel,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _body(theme)),
          UtenBottomActionBar(
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: _saving ? null : _cancel,
                  child: const Text('取消'),
                ),
                UtenButton(
                  key: const ValueKey('client-access-save'),
                  icon: Icons.save_outlined,
                  isLoading: _saving,
                  onPressed: !_loading && _dirty && !_saving ? _save : null,
                  child: const Text('保存设置'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return UtenEmpty.error(
        message: _loadError,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        children: [
          Container(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
              borderRadius: UtenRadius.mdAll,
            ),
            child: Text(
              '内销、外贸客户使用同一套规则。可同时设置多位负责人，共同维护客户普通资料；'
              '历史制单、审批和审计记录不会被改写。变更负责人时，若原负责人仍在职且账号启用，'
              '系统会暂时保留其单客户只读查看权，以便完成在途单据。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenEmployeeMultiPicker(
            key: const ValueKey('client-access-owners'),
            label: '客户负责人',
            hint: '请选择一位或多位负责人',
            info: '第一位是主负责人，承接未指定负责人的新业务；所有选中人员均可共同维护客户普通资料。',
            sheetTitle: '选择客户负责人',
            initialSelection: _owners,
            panelScopeBuilder: widget.submissionOwner?.ownDialog,
            required: true,
            enabled: !_saving,
            selectedCountLabel: (count) => '负责人 $count 人',
            validator: (selection) => selection.isEmpty ? '请至少选择一位客户负责人' : null,
            loader: (keyword) => _loadEmployees(keyword),
            onChanged: _changeOwners,
          ),
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '额外可见人只获得该客户的只读查看，不改变负责人；是否可执行其他操作仍由独立操作权限决定。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          UtenEmployeeMultiPicker(
            key: ValueKey(
              'client-access-viewers-${_owners.map((owner) => owner.id).join(',')}-'
              '${_viewers.map((viewer) => viewer.id).join(',')}',
            ),
            label: '额外只读查看人',
            hint: '没有额外查看人',
            sheetTitle: '选择额外只读查看人',
            emptyMessage: '未找到匹配的在册员工',
            initialSelection: _viewers,
            panelScopeBuilder: widget.submissionOwner?.ownDialog,
            selectedCountLabel: (count) => '额外查看 $count 人',
            enabled: !_saving,
            loader: (keyword) => _loadEmployees(keyword, excludeOwner: true),
            onChanged: (selection) => setState(() {
              _viewers = selection
                  .where(
                    (viewer) => !_owners.any((owner) => owner.id == viewer.id),
                  )
                  .toList(growable: false);
            }),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '保存后以服务器返回的查看人名单为准。后续要移除查看人时，请先确认对方没有引用该客户的未完成草稿，'
            '否则草稿可能无法继续打开或提交。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenInput(
            key: const ValueKey('client-access-reason'),
            controller: _reasonController,
            label: '修改原因',
            hint: '例如：客户交接、协同跟进或临时查看',
            inputFormatters: [LengthLimitingTextInputFormatter(1000)],
            maxLines: 3,
            required: true,
            enabled: !_saving,
            validator: (value) {
              final reason = value?.trim() ?? '';
              if (reason.isEmpty) return '请填写修改原因，便于审计追溯';
              return reason.length > 1000 ? '修改原因不能超过 1000 个字符' : null;
            },
          ),
        ],
      ),
    );
  }
}

bool _sameIds(Set<String> left, Set<String> right) =>
    left.length == right.length && left.every(right.contains);

bool _sameOrderedIds(List<String> left, List<String> right) =>
    left.length == right.length &&
    Iterable<int>.generate(
      left.length,
    ).every((index) => left[index] == right[index]);
