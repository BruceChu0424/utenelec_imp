import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../models/server_storage.dart';
import '../providers/server_operations_access.dart';
import '../providers/server_storage_request_store.dart';
import '../repositories/server_storage_repository.dart';

class ServerStoragePage extends ConsumerWidget {
  const ServerStoragePage({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => _ServerStorageSession(
    key: ValueKey((
      ref.watch(serverOperationsOwnerProvider),
      ref.watch(serverOperationsVisibleProvider),
    )),
  );
}

class _ServerStorageSession extends ConsumerStatefulWidget {
  const _ServerStorageSession({super.key});
  @override
  ConsumerState<_ServerStorageSession> createState() => _ServerStorageState();
}

class _ServerStorageState extends ConsumerState<_ServerStorageSession>
    with WidgetsBindingObserver {
  late final Object? _owner;
  late final String? _requestOwner;
  ServerStorageSummary? _summary;
  ServerStorageResources? _resources;
  ServerStorageCategory? _category;
  ServerStorageCleanupReceipt? _receipt;
  final Set<String> _selected = {};
  bool _loading = false, _itemsLoading = false, _busy = false;
  int _generation = 0, _itemsGeneration = 0;
  String? _error, _itemsError;
  String? _pending;
  Timer? _receiptTimer;
  bool _receiptLoading = false, _foreground = true, _visible = true;
  int _receiptAttempts = 0;
  bool get _current =>
      mounted &&
      _owner != null &&
      _owner == ref.read(serverOperationsOwnerProvider) &&
      _requestOwner == ref.read(serverStorageRequestOwnerProvider) &&
      ref.read(serverOperationsVisibleProvider);
  bool get _active => _current && _foreground && _visible;
  bool get _canCleanup =>
      _current &&
      _requestOwner != null &&
      ref.read(serverOperationsWritableProvider) &&
      _summary?.available == true &&
      _summary?.canCleanup == true &&
      !_loading &&
      !_busy &&
      _receipt?.status != 'RECOVERY_REQUIRED' &&
      _pending == null;
  ServerStorageRepository get _repository =>
      ref.read(serverStorageRepositoryProvider);

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    _requestOwner = ref.read(serverStorageRequestOwnerProvider);
    if (_requestOwner != null) {
      _pending = ref
          .read(serverStorageRequestStoreProvider)
          .read(_requestOwner);
    }
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _foreground = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _load();
      _checkReceipt();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _receiptTimer?.cancel();
    if (_active) unawaited(_checkReceipt(manual: true));
  }

  @override
  void dispose() {
    _generation++;
    _itemsGeneration++;
    _receiptTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _loading || _busy) return;
    final generation = ++_generation;
    _itemsGeneration++;
    setState(() {
      _loading = true;
      _error = null;
      _selected.clear();
      _resources = null;
      _itemsError = null;
      _itemsLoading = false;
    });
    try {
      final result = await _repository.summary();
      if (!_current || generation != _generation) return;
      setState(() => _summary = result);
      if (_category != null) {
        final matching = result.categories.where(
          (row) => row.kind == _category!.kind,
        );
        _category = matching.isEmpty ? null : matching.first;
      }
    } catch (error) {
      if (_current && generation == _generation) {
        setState(() {
          _error = _message(error, '无法读取存储用量。');
          _summary = null;
        });
      }
    } finally {
      if (_current && generation == _generation) {
        setState(() => _loading = false);
        if (_category != null) unawaited(_loadItems());
      }
    }
  }

  Future<void> _loadItems({bool more = false}) async {
    final category = _category;
    if (!_current ||
        _summary?.available != true ||
        category == null ||
        _itemsLoading ||
        _busy ||
        !category.canList) {
      return;
    }
    final cursor = more ? _resources?.nextCursor : null;
    if (more && cursor == null) return;
    final generation = ++_itemsGeneration;
    setState(() {
      _itemsLoading = true;
      _itemsError = null;
      if (!more) {
        _resources = null;
        _selected.clear();
      }
    });
    try {
      final result = await _repository.resources(category.kind, cursor: cursor);
      if (!_current ||
          generation != _itemsGeneration ||
          _category?.kind != category.kind) {
        return;
      }
      if (result.kind != category.kind) {
        throw const FormatException('Invalid inventory category');
      }
      final previous = _resources;
      if (more && previous != null && previous.revision != result.revision) {
        setState(() {
          _selected.clear();
          _resources = null;
          _itemsError = '存储内容已变化，请重新读取此分类后再选择。';
        });
        return;
      }
      setState(
        () => _resources = more && previous != null
            ? result.withItems([...previous.items, ...result.items])
            : result,
      );
    } catch (error) {
      if (_current && generation == _itemsGeneration) {
        setState(() => _itemsError = _message(error, '无法读取此分类，请重试。'));
      }
    } finally {
      if (_current && generation == _itemsGeneration) {
        setState(() => _itemsLoading = false);
      }
    }
  }

  Future<void> _preview() async {
    if (!_canCleanup || _selected.isEmpty) return;
    final ids = _selected.toList()..sort();
    setState(() {
      _busy = true;
      _error = null;
    });
    ServerStoragePreview? preview;
    try {
      preview = await _repository.preview(ids);
      if (!mounted || !_current) return;
      if (preview.previewId.isEmpty ||
          preview.expiresAt == null ||
          !preview.expiresAt!.isAfter(clock.now().toUtc()) ||
          preview.resources.isEmpty ||
          preview.resources.any((item) => !item.canDelete) ||
          preview.resources.map((item) => item.id).toSet().length !=
              ids.length ||
          !preview.resources.every((item) => _selected.contains(item.id))) {
        throw const FormatException('Unsafe cleanup preview');
      }
      // The network preview is complete. Do not keep a spinner running behind
      // a confirmation while the user reviews protected resource facts.
      setState(() => _busy = false);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => UtenAlertDialog(
          title: const Text('确认清理所选资源'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(preview!.confirmationText),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '共 ${preview.resources.length} 项，预计释放 ${formatStorageBytes(preview.totalReclaimableBytes)}',
              ),
              for (final resource in preview.resources)
                Text('• ${resource.label}'),
              for (final warning in preview.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(warning),
                ),
              Text(
                '确认有效期：${DisplayDateTime.beijing(preview.expiresAt!.toIso8601String())}',
              ),
            ],
          ),
          actions: [
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            UtenButton(
              key: const ValueKey('storage-cleanup-confirm'),
              type: UtenButtonType.danger,
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认清理'),
            ),
          ],
        ),
      );
      if (!_current || confirmed != true) return;
      if (!preview.expiresAt!.isAfter(clock.now().toUtc())) {
        throw StateError('Preview expired');
      }
      await _executeOnce(preview.previewId);
    } catch (error) {
      if (_current) {
        setState(() => _error = _message(error, '清理预览已失效或无法核实，请刷新存储后重试。'));
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
    if (_current && _pending == null && _receipt != null) await _load();
  }

  Future<void> _executeOnce(String previewId) async {
    if (!_current || _requestOwner == null || _pending != null) return;
    final requestId = const Uuid().v4();
    setState(() {
      _busy = true;
      _error = null;
    });
    var tracked = false;
    try {
      await ref
          .read(serverStorageRequestStoreProvider)
          .remember(_requestOwner, requestId);
      if (!_current) return;
      tracked = true;
      setState(() {
        _pending = requestId;
        _receipt = null;
        _receiptAttempts = 0;
      });
      final result = await _repository.cleanup(
        previewId: previewId,
        requestId: requestId,
      );
      if (!_current) return;
      _acceptReceipt(result);
    } catch (error) {
      if (_current) {
        setState(
          () => _error = tracked
              ? '清理结果尚未确认。仅查询原请求回执，不会再次提交清理。'
              : '无法保存本机请求追踪，尚未提交清理。',
        );
      }
    } finally {
      if (_current) {
        setState(() => _busy = false);
        _scheduleReceipt();
      }
    }
  }

  void _acceptReceipt(ServerStorageCleanupReceipt result) {
    setState(() {
      _receipt = result;
      _selected.clear();
      _error = null;
      _pending = result.status == 'RUNNING' ? result.requestId : null;
    });
  }

  void _scheduleReceipt() {
    _receiptTimer?.cancel();
    if (_active && _pending != null && _receiptAttempts < 24) {
      _receiptTimer = Timer(const Duration(seconds: 5), () => _checkReceipt());
    }
  }

  Future<void> _checkReceipt({bool manual = false}) async {
    final requestId = _pending;
    if (!_active || requestId == null || _receiptLoading || _busy) return;
    if (manual) _receiptAttempts = 0;
    _receiptAttempts++;
    _receiptTimer?.cancel();
    setState(() => _receiptLoading = true);
    try {
      final result = await _repository.receipt(requestId);
      if (!_current || _pending != requestId) return;
      _acceptReceipt(result);
      if (_pending == null) unawaited(_load());
    } catch (_) {
      if (_current && _pending == requestId) {
        setState(
          () => _error = '原清理回执尚未确认，未找到回执也不能代表没有执行。请稍后核对或联系管理员，系统不会重新提交。',
        );
      }
    } finally {
      if (_current) {
        setState(() => _receiptLoading = false);
        _scheduleReceipt();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final allowed =
        ref.watch(serverOperationsVisibleProvider) && _owner != null;
    ref.listen(pageResumeProvider, (_, next) {
      if (next.location.isEmpty) return;
      final visible = next.location == RouteName.adminServerStorage;
      if (visible == _visible) return;
      _visible = visible;
      _receiptTimer?.cancel();
      if (_active) unawaited(_checkReceipt(manual: true));
    });
    final summary = _summary;
    return Scaffold(
      appBar: UtenAppBar(
        title: '服务器存储管理',
        showBackButton: true,
        showPagePermissionAction: false,
        actions: [
          IconButton(
            key: const ValueKey('server-storage-refresh'),
            tooltip: '刷新本机存储',
            onPressed: allowed && !_busy && !_loading
                ? () async {
                    await _load();
                    await _checkReceipt(manual: true);
                  }
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: !allowed
          ? const UtenEmpty(icon: Icons.lock_outline, message: '没有服务器运维查看权限')
          : SafeArea(
              child: SingleChildScrollView(
                child: UtenContentContainer(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_loading) const LinearProgressIndicator(),
                      if (_error != null)
                        UtenInlineNotice(
                          level: UtenInlineNoticeLevel.error,
                          message: _error,
                        ),
                      if (_pending != null)
                        UtenInlineNotice(
                          level: UtenInlineNoticeLevel.warning,
                          title: _receipt?.status == 'RUNNING'
                              ? '清理作业正在运行'
                              : '上次清理结果待核对',
                          message: _receiptAttempts >= 24
                              ? '自动核对已暂停，请稍后手动核对或联系管理员。不会重新执行清理。'
                              : '只查询同一请求的本机回执，不会再次提交清理。',
                          trailing: UtenButton(
                            type: UtenButtonType.secondary,
                            onPressed: _busy || _receiptLoading
                                ? null
                                : () async {
                                    await _checkReceipt(manual: true);
                                  },
                            child: const Text('核对原请求'),
                          ),
                        ),
                      if (_receipt != null)
                        UtenInlineNotice(
                          level: _receipt!.status == 'SUCCEEDED'
                              ? UtenInlineNoticeLevel.info
                              : UtenInlineNoticeLevel.warning,
                          title: switch (_receipt!.status) {
                            'RUNNING' => '清理进行中',
                            'RECOVERY_REQUIRED' => '需要核查清理恢复状态',
                            'SUCCEEDED' => '清理完成',
                            'PARTIAL' => '部分清理完成',
                            _ => '清理未完成',
                          },
                          message:
                              '已清理 ${_receipt!.deletedCount ?? '—'} 项，估算释放 ${formatStorageBytes(_receipt!.reclaimedBytes)}。${_receipt!.detail ?? ''}',
                        ),
                      if (_pending != null || _receipt != null)
                        SelectableText(
                          '清理请求：${_pending ?? _receipt!.requestId}',
                        ),
                      if (summary != null) ...[
                        Text(
                          '本机资源用量',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        if (summary.sampledAt != null)
                          Text(
                            '采样：${DisplayDateTime.beijing(summary.sampledAt!.toIso8601String())}',
                          ),
                        if (!summary.available)
                          UtenInlineNotice(
                            key: const ValueKey('storage-unavailable'),
                            level: summary.platformUnsupported
                                ? UtenInlineNoticeLevel.info
                                : UtenInlineNoticeLevel.warning,
                            message:
                                summary.unavailableReason ?? '此服务器暂未提供存储管理能力。',
                          ),
                        const SizedBox(height: UtenSpacing.s12),
                        _metrics(summary),
                        if (summary.processDetail != null)
                          Text(summary.processDetail!),
                        if (summary.uploadDetail != null)
                          Text(summary.uploadDetail!),
                        const SizedBox(height: UtenSpacing.s16),
                        for (final volume in summary.volumes)
                          ListTile(
                            leading: const Icon(Icons.dns_outlined),
                            title: Text(volume.label),
                            subtitle: Text(
                              '已用及系统保留 ${formatStorageBytes(volume.usedBytes)} / ${formatStorageBytes(volume.totalBytes)} · 可用 ${formatStorageBytes(volume.freeBytes)}',
                            ),
                          ),
                        const SizedBox(height: UtenSpacing.s16),
                        const Text(
                          '按资源分类查看。逻辑大小、磁盘占用和预计可释放空间分别计量；受保护资源不会提供删除选项。',
                        ),
                        const SizedBox(height: UtenSpacing.s12),
                        LayoutBuilder(
                          builder: (context, constraints) => Wrap(
                            spacing: 12,
                            runSpacing: 12,
                            children: [
                              for (final category in summary.categories)
                                SizedBox(
                                  width: constraints.maxWidth < 650
                                      ? constraints.maxWidth
                                      : (constraints.maxWidth - 12) / 2,
                                  child: UtenCard(
                                    child: ListTile(
                                      key: ValueKey(
                                        'storage-category-${category.kind}',
                                      ),
                                      selected:
                                          _category?.kind == category.kind,
                                      title: Text(category.displayLabel),
                                      subtitle: Text(
                                        '磁盘占用 ${formatStorageBytes(category.allocatedBytes)} · 逻辑 ${formatStorageBytes(category.logicalBytes)}\n估算可释放 ${formatStorageBytes(category.reclaimableBytes)} · 直属条目 ${category.count ?? '—'}',
                                      ),
                                      trailing: category.canList
                                          ? const Icon(Icons.chevron_right)
                                          : null,
                                      onTap:
                                          summary.available &&
                                              category.canList &&
                                              !_busy &&
                                              !_loading &&
                                              _pending == null
                                          ? () {
                                              _itemsGeneration++;
                                              setState(() {
                                                _category = category;
                                                _resources = null;
                                                _selected.clear();
                                                _itemsLoading = false;
                                                _itemsError = null;
                                              });
                                              _loadItems();
                                            }
                                          : null,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (_category != null) ...[
                          const SizedBox(height: UtenSpacing.s24),
                          Text(
                            _category!.displayLabel,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          if (_category!.detail != null)
                            Text(_category!.detail!),
                          if (_itemsError != null)
                            UtenInlineNotice(
                              level: UtenInlineNoticeLevel.error,
                              message: _itemsError,
                              trailing: UtenButton(
                                type: UtenButtonType.secondary,
                                onPressed: _itemsLoading ? null : _loadItems,
                                child: const Text('重新读取'),
                              ),
                            ),
                          if (_resources != null)
                            Text(
                              '已显示 ${_resources!.items.length} / ${_resources!.total ?? '—'} 项',
                            ),
                          if (_summary?.canCleanup == true)
                            const Text('每次最多选择 50 项；受保护资源不可选择。'),
                          if (_itemsLoading) const LinearProgressIndicator(),
                          if (!_itemsLoading &&
                              _resources?.items.isEmpty == true)
                            const UtenEmpty(message: '此分类暂无资源'),
                          for (final resource
                              in _resources?.items ?? <ServerStorageResource>[])
                            _resource(resource),
                          if (_resources?.nextCursor != null)
                            UtenButton(
                              type: UtenButtonType.secondary,
                              onPressed: _itemsLoading || _busy
                                  ? null
                                  : () => _loadItems(more: true),
                              child: const Text('加载更多'),
                            ),
                          if (_summary?.canCleanup == true)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: UtenSpacing.s16,
                              ),
                              child: Align(
                                alignment: Alignment.centerRight,
                                child: UtenButton(
                                  key: const ValueKey(
                                    'storage-cleanup-preview',
                                  ),
                                  type: UtenButtonType.danger,
                                  icon: Icons.delete_outline,
                                  onPressed:
                                      _canCleanup &&
                                          _selected.isNotEmpty &&
                                          !_itemsLoading
                                      ? _preview
                                      : null,
                                  isLoading: _busy,
                                  child: Text('预览清理（${_selected.length}）'),
                                ),
                              ),
                            ),
                        ],
                      ],
                      const SizedBox(height: UtenSpacing.s24),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _metrics(ServerStorageSummary summary) => Wrap(
    spacing: 12,
    runSpacing: 12,
    children: [
      _metric('进程驻留内存', formatStorageBytes(summary.rssBytes)),
      _metric(
        '应用堆内存',
        '${formatStorageBytes(summary.heapUsedBytes)} / ${formatStorageBytes(summary.heapMaxBytes)}',
      ),
      _metric('数据库', formatStorageBytes(summary.databaseBytes)),
      _metric(
        '上传附件登记量',
        '${summary.uploadCount ?? '—'} 项 · ${formatStorageBytes(summary.uploadStoredBytes)}',
      ),
    ],
  );
  Widget _metric(String label, String value) => UtenCard(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label),
          Text(value, style: Theme.of(context).textTheme.titleMedium),
        ],
      ),
    ),
  );
  Widget _resource(ServerStorageResource resource) => Card(
    margin: const EdgeInsets.symmetric(vertical: 5),
    child: ListTile(
      leading: resource.canDelete && _summary?.canCleanup == true
          ? Checkbox(
              key: ValueKey('storage-select-${resource.id}'),
              value: _selected.contains(resource.id),
              onChanged:
                  _canCleanup &&
                      !_itemsLoading &&
                      (_selected.contains(resource.id) || _selected.length < 50)
                  ? (value) => setState(() {
                      if (value == true) {
                        _selected.add(resource.id);
                      } else {
                        _selected.remove(resource.id);
                      }
                    })
                  : null,
            )
          : const Icon(Icons.shield_outlined),
      title: Text(resource.label),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '磁盘占用 ${formatStorageBytes(resource.allocatedBytes)} · 逻辑 ${formatStorageBytes(resource.logicalBytes)} · 估算可释放 ${formatStorageBytes(resource.reclaimableBytes)}',
          ),
          if (resource.modifiedAt != null)
            Text(
              '修改：${DisplayDateTime.beijing(resource.modifiedAt!.toIso8601String())}',
            ),
          if (resource.detail != null) Text(resource.detail!),
          for (final reason in resource.protectionReasons) Text(reason),
        ],
      ),
    ),
  );
  String _message(Object error, String fallback) =>
      error is ApiException ? error.message : fallback;
}

String formatStorageBytes(int? bytes) {
  if (bytes == null) return '尚未确认';
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble(), index = 0;
  const units = ['KiB', 'MiB', 'GiB', 'TiB'];
  do {
    value /= 1024;
    index++;
  } while (value >= 1024 && index < units.length);
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[index - 1]}';
}
