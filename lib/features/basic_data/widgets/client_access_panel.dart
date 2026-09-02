import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
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
import '../models/client_access_models.dart';
import '../repositories/client_repository.dart';

typedef ClientAccessLoader = Future<ClientAccessSettings> Function(
  String clientId,
);
typedef ClientAccessSaver = Future<ClientAccessSettings> Function(
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
}) => showUtenAdaptivePanel<ClientAccessSettings>(
  context: context,
  drawerWidth: 480,
  barrierDismissible: false,
  showDragHandle: true,
  builder: (_) => ClientAccessPanel(
    clientId: clientId,
    clientName: clientName,
    loader: loader,
    saver: saver,
  ),
);

class ClientAccessPanel extends ConsumerStatefulWidget {
  const ClientAccessPanel({
    super.key,
    required this.clientId,
    required this.clientName,
    required this.loader,
    required this.saver,
  });

  final String clientId;
  final String clientName;
  final ClientAccessLoader loader;
  final ClientAccessSaver saver;

  @override
  ConsumerState<ClientAccessPanel> createState() => _ClientAccessPanelState();
}

class _ClientAccessPanelState extends ConsumerState<ClientAccessPanel> {
  final _formKey = GlobalKey<FormState>();
  final _reasonController = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  int _accessVersion = 0;

  UtenEmployeePickerItem? _owner;
  List<UtenEmployeePickerItem> _viewers = const [];
  String? _initialOwnerId;
  String? _initialOwnerName;
  Set<String> _initialViewerIds = const {};

  bool get _dirty {
    final currentViewerIds = _viewers.map((item) => item.id).toSet();
    return _owner?.id != _initialOwnerId ||
        !_sameIds(currentViewerIds, _initialViewerIds);
  }

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
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final settings = await widget.loader(widget.clientId);
      if (!mounted) return;
      _apply(settings);
      _reasonController.clear();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadError = '客户访问设置加载失败，请重试');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _apply(ClientAccessSettings settings) {
    final ownerId = settings.ownerEmployeeId;
    final ownerName = settings.ownerEmployeeName?.trim();
    final viewers = settings.viewers
        .where((viewer) => viewer.employeeId != ownerId)
        .map(
          (viewer) => UtenEmployeePickerItem(
            id: viewer.employeeId,
            name: viewer.name,
            employeeCode: viewer.code,
            departmentName: _personSubtitle(
              departmentName: viewer.departmentName,
            ),
          ),
        )
        .toList(growable: false);
    setState(() {
      _accessVersion = settings.accessVersion;
      _owner = ownerId == null || ownerId.isEmpty
          ? null
          : UtenEmployeePickerItem(
              id: ownerId,
              name: ownerName == null || ownerName.isEmpty ? '未知员工' : ownerName,
            );
      _viewers = viewers;
      _initialOwnerId = ownerId;
      _initialOwnerName = ownerName;
      _initialViewerIds = viewers.map((item) => item.id).toSet();
    });
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(
    String? keyword, {
    bool excludeOwner = false,
  }) async {
    final repository = ref.read(clientRepositoryProvider);
    final rows = <ClientAccessCandidate>[];
    var page = 1;
    var total = 1;
    do {
      final result = await repository.accessCandidates(
        page: page,
        search: keyword,
      );
      rows.addAll(result.items);
      total = result.total;
      page++;
      // 最小候选API服务端搜索；空关键词最多预取500人，超出时继续输入姓名/工号检索。
    } while (rows.length < total && page <= 25);

    return rows
        .where(
          (employee) =>
              employee.activeAccount &&
              (!excludeOwner || employee.employeeId != _owner?.id),
        )
        .map(
          (employee) => UtenEmployeePickerItem(
            id: employee.employeeId,
            name: employee.name,
            employeeCode: employee.code,
            departmentName: _personSubtitle(
              departmentName: employee.departmentName,
              status: employee.status,
            ),
          ),
        )
        .toList(growable: false);
  }

  void _changeOwner(UtenEmployeePickerItem? next) {
    if (next == null) return;
    setState(() {
      _owner = next;
      _viewers = _viewers
          .where((viewer) => viewer.id != next.id)
          .toList(growable: false);
    });
  }

  Future<void> _save() async {
    if (_saving || !_dirty) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final owner = _owner;
    if (owner == null) return;
    final reason = _reasonController.text.trim();
    final viewerIds =
        _viewers
            .map((viewer) => viewer.id)
            .where((id) => id != owner.id)
            .toSet()
            .toList()
          ..sort();
    final confirmed = await UtenDialog.show(
      context,
      title: '确认保存客户访问设置？',
      content: Text(
        '客户：${widget.clientName}\n'
        '负责人：${owner.name}\n'
        '额外只读查看人：${viewerIds.length} 人\n\n'
        '本次修改不会改写历史制单、审批或审计记录。'
        '${_initialOwnerId != null && _initialOwnerId != owner.id ? '\n\n原负责人${_initialOwnerName?.isNotEmpty == true ? ' ${_initialOwnerName!}' : ''}如仍在职且账号启用，系统会暂时保留其只读查看权以完成在途单据；最终以保存回执为准。' : ''}',
      ),
      confirmLabel: '确认保存',
    );
    if (!mounted || confirmed != true) return;

    setState(() => _saving = true);
    try {
      final saved = await widget.saver(
        widget.clientId,
        ClientAccessUpdate(
          ownerEmployeeId: owner.id,
          viewerEmployeeIds: viewerIds,
          expectedAccessVersion: _accessVersion,
          reason: reason,
        ),
      );
      if (!mounted) return;
      context.appSuccess('负责人和可见人已保存；当前额外查看 ${saved.viewers.length} 人');
      Navigator.of(context).pop(saved);
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        context.appError('设置已被其他人更新，已为你刷新最新数据');
        await _load();
      } else {
        context.appApiError(error);
      }
    } catch (_) {
      if (mounted) context.appError('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _cancel() async {
    if (_saving) return;
    if (_dirty) {
      final discard = await UtenDialog.show(
        context,
        title: '放弃未保存修改？',
        content: const Text('负责人或额外可见人已经修改，离开后不会保存。'),
        confirmLabel: '放弃修改',
        danger: true,
      );
      if (!mounted || discard != true) return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope<void>(
      canPop: !_dirty && !_saving,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_cancel());
      },
      child: Column(
        key: const ValueKey('client-access-panel'),
        children: [
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
              '内销、外贸客户使用同一套规则。负责人表示当前业务责任；'
              '历史制单、审批和审计记录不会被改写。变更负责人时，若原负责人仍在职且账号启用，'
              '系统会暂时保留其单客户只读查看权，以便完成在途单据。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          UtenEmployeePicker(
            key: ValueKey('client-access-owner-${_owner?.id ?? 'none'}'),
            label: '客户负责人',
            hint: '请选择在册负责人',
            sheetTitle: '选择客户负责人',
            initial: _owner,
            required: true,
            validator: (value) => value == null ? '请选择客户负责人' : null,
            loader: (keyword) => _loadEmployees(keyword),
            onChanged: _changeOwner,
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
              'client-access-viewers-${_owner?.id ?? 'none'}-'
              '${_viewers.map((viewer) => viewer.id).join(',')}',
            ),
            label: '额外只读查看人',
            hint: '没有额外查看人',
            sheetTitle: '选择额外只读查看人',
            emptyMessage: '未找到匹配的在册员工',
            initialSelection: _viewers,
            selectedCountLabel: (count) => '额外查看 $count 人',
            enabled: !_saving,
            loader: (keyword) => _loadEmployees(keyword, excludeOwner: true),
            onChanged: (selection) => setState(() {
              _viewers = selection
                  .where((viewer) => viewer.id != _owner?.id)
                  .toList(growable: false);
            }),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '保存后以服务端返回的查看人列表为准。后续移除查看人前，请先确认其没有引用该客户的在途草稿，'
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

String? _personSubtitle({String? departmentName, String? status}) {
  final parts = <String>[
    if (departmentName?.trim().isNotEmpty == true) departmentName!.trim(),
    if (status?.trim().isNotEmpty == true) _statusLabel(status!.trim()),
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

String _statusLabel(String status) => switch (status) {
  'active' => '在职',
  'probation' => '试用',
  'onLeave' => '休假',
  _ => status,
};
