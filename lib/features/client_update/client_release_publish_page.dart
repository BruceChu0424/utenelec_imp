import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/inputs/uten_dropdown_scroll_scope.dart';
import '../../components/layout/uten_app_bar.dart';
import '../../components/layout/uten_content_container.dart';
import '../../core/network/api_client.dart';
import '../../core/network/server_config.dart';
import '../../core/router/nav_helpers.dart';
import '../../core/theme/uten_tokens.dart';
import '../../shared/drafts/form_draft_navigation.dart';
import '../../shared/drafts/form_draft_store.dart';
import '../../shared/providers/authenticated_scope_provider.dart';
import '../../shared/providers/sensitive_read_boundary_provider.dart';
import 'client_release.dart';
import 'client_release_access.dart';
import 'client_release_publish_drafts.dart';
import 'client_release_publish_queue.dart';
import 'software_downloads_presentation.dart';

typedef ClientReleaseFilePicker =
    Future<List<ClientReleasePickedFile>> Function(bool multiple);
final clientReleaseFilePickerProvider = Provider<ClientReleaseFilePicker>(
  (ref) => (multiple) async {
    final selected = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['exe', 'zip', 'apk'],
      allowMultiple: multiple,
      withReadStream: true,
    );
    if (selected == null) return [];
    return selected.files
        .map((file) {
          final stream = file.readStream;
          if (stream != null) {
            return ClientReleasePickedFile(
              name: file.name,
              size: file.size,
              openRead: () => stream,
            );
          }
          final bytes = file.bytes;
          if (bytes != null) {
            return ClientReleasePickedFile.bytes(file.name, bytes);
          }
          throw StateError('所选文件无法读取，请重新选择。');
        })
        .toList(growable: false);
  },
);
final clientReleasePublishGatewayProvider =
    Provider<ClientReleasePublishGateway>(
      (ref) => ApiClientReleasePublishGateway(ref.watch(apiClientProvider)),
    );

/// A route-sized publishing workspace shared by both existing entrypoints.
class ClientReleasePublishPage extends ConsumerStatefulWidget {
  const ClientReleasePublishPage({
    super.key,
    this.initialPlatform = 'windows',
    this.initialRuntimeFamily = ClientRuntimeFamily.flutter,
    this.initialArchitecture = 'x64',
    this.initialPackageKind = 'update',
    this.onPublished,
  });
  final String initialPlatform,
      initialRuntimeFamily,
      initialArchitecture,
      initialPackageKind;
  final ValueChanged<List<ClientRelease>>? onPublished;
  @override
  ConsumerState<ClientReleasePublishPage> createState() => _PublishPageState();
}

class _PublishPageState extends ConsumerState<ClientReleasePublishPage> {
  final _version = TextEditingController(),
      _build = TextEditingController(),
      _notes = TextEditingController(),
      _store = TextEditingController();
  late ClientReleasePublishMetadata _context;
  late final ClientReleasePublishQueue _queue;
  late final ApiClient _api;
  late final AuthenticatedScope? _owner;
  late final SensitiveReadBoundary _boundary;
  late final String _server;
  ClientReleasePublishDraftLease? _draft;
  Timer? _draftTimer;
  bool _ready = false,
      _retired = false,
      _choosing = false,
      _exitAllowed = false,
      _hadInput = false,
      _discarded = false,
      _discarding = false;
  Object? _storageError;
  String? _notice;
  Future<bool>? _leave;
  final _reported = <String>{};
  bool get _current =>
      mounted &&
      !_retired &&
      _owner != null &&
      ref.read(clientReleasePublisherProvider) == _owner &&
      identical(ref.read(apiClientProvider), _api) &&
      ref.read(sensitiveReadBoundaryProvider) == _boundary &&
      ref.read(apiBaseUrlProvider) == _server;
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _owner = ref.read(clientReleasePublisherProvider);
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _server = ref.read(apiBaseUrlProvider);
    _context = ClientReleasePublishMetadata(
      platform: widget.initialPlatform,
      runtimeFamily: widget.initialRuntimeFamily,
      architecture: widget.initialArchitecture,
      packageKind: widget.initialPackageKind,
    );
    _queue = ClientReleasePublishQueue(
      gateway: ref.read(clientReleasePublishGatewayProvider),
      isCurrent: () => _current,
      checkpoint: _checkpoint,
    );
    _queue.addListener(_queueChanged);
    for (final controller in [_version, _build, _notes, _store]) {
      controller.addListener(_contextChanged);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  Future<void> _initialize() async {
    if (!_current) return;
    try {
      final route = goRouterPageStateOrNull(context);
      final draft = _draft ??= ClientReleasePublishDraftLease(
        storage: ref.read(formDraftStorageProvider),
        server: _server,
        owner: _owner!,
        draftId: route?.uri.queryParameters['draftId'],
      );
      final saved = await draft.load();
      if (!_current) return;
      if (saved != null) {
        _queue.restore(saved.data);
        _hadInput = true;
        if (saved.data['context'] case final Map<Object?, Object?> context) {
          _context = ClientReleasePublishMetadata.fromJson(
            Map<String, dynamic>.from(context),
          );
          _version.text = _context.version;
          _build.text = _context.buildNumber;
          _notes.text = _context.releaseNotes;
          _store.text = _context.storeUrl;
        }
        _notice = '已恢复发布元数据。原提交先核对状态；文件内容不会保存在草稿中，请按提示重选原文件。';
      }
      FormDraftNavigation.register(
        this,
        clientReleasePublishRoute,
        _confirmLeave,
        pageKey: route?.pageKey,
      );
      setState(() {
        _ready = true;
        _storageError = null;
      });
      try {
        await _queue.load();
      } catch (_) {
        if (_current) setState(() => _notice = '发布列表暂未读取完整，已保留当前队列。');
      }
    } catch (error) {
      if (mounted) setState(() => _storageError = error);
    }
  }

  Map<String, dynamic> _snapshot([Map<String, dynamic>? queue]) => {
    ...(queue ?? _queue.snapshot()),
    'context': _context.toJson(),
  };
  Future<void> _checkpoint(Map<String, dynamic> queue) async {
    if (_discarded) return;
    if (_discarding) throw StateError('正在确认丢弃原草稿');
    final draft = _draft;
    if (draft == null) throw StateError('本机发布草稿保护尚未就绪');
    await draft.save(_snapshot(queue));
    if (mounted) setState(() => _storageError = null);
  }

  Future<void> _saveDraft() async {
    if (!_hadInput && _queue.items.isEmpty) return;
    await _checkpoint(_queue.snapshot());
  }

  void _queueChanged() {
    if (!mounted) return;
    setState(() {});
    if (_ready && !_retired && !_discarding && !_discarded) {
      _draftTimer?.cancel();
      _draftTimer = Timer(const Duration(milliseconds: 300), () {
        unawaited(
          _saveDraft().catchError((Object error) {
            if (mounted) setState(() => _storageError = error);
          }),
        );
      });
    }
    if (_current) {
      final confirmed = _queue.items
          .where((item) => item.published)
          .map((item) => item.publishedRelease)
          .whereType<ClientRelease>()
          .where((record) => record.state == 'PUBLISHED')
          .toList(growable: false);
      final newIds = confirmed
          .map((item) => item.id)
          .where((id) => !_reported.contains(id))
          .toList();
      if (newIds.isNotEmpty) {
        _reported.addAll(newIds);
        widget.onPublished?.call(confirmed);
      }
    }
  }

  void _contextChanged() {
    if (_retired || !_ready) return;
    _hadInput = true;
    setState(
      () => _context = _context.copyWith(
        version: _version.text,
        buildNumber: _build.text,
        releaseNotes: _notes.text,
        storeUrl: _store.text,
      ),
    );
    _queueChanged();
  }

  void _setTarget(ClientReleasePublishMetadata metadata) {
    if (!_current || _queue.busy) return;
    _hadInput = true;
    setState(() => _context = metadata);
    if (_store.text != metadata.storeUrl) _store.text = metadata.storeUrl;
    _queueChanged();
  }

  Future<void> _pick(bool multiple, [ClientReleaseQueueItem? replacing]) async {
    if (!_ready || !_current || _queue.busy || _choosing) return;
    setState(() => _choosing = true);
    try {
      final files = await ref.read(clientReleaseFilePickerProvider)(multiple);
      if (!_current || files.isEmpty) return;
      _hadInput = true;
      if (replacing != null) {
        _queue.replaceFile(replacing, files.single);
      } else {
        _queue.addFiles(files, _context);
      }
      await _saveDraft();
    } catch (error) {
      if (_current) setState(() => _notice = _human(error));
    } finally {
      if (mounted) setState(() => _choosing = false);
    }
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _draftTimer?.cancel();
    _queue.retire();
    unawaited(
      _saveDraft().catchError((Object error) {
        if (mounted) setState(() => _storageError = error);
      }),
    );
    for (final controller in [_version, _build, _notes, _store]) {
      controller.clear();
    }
    if (mounted) setState(() {});
  }

  Future<bool> _confirmLeave() =>
      _leave ??= _leaveNow().whenComplete(() => _leave = null);
  Future<bool> _leaveNow() async {
    if (_exitAllowed) return true;
    if (_queue.busy || _choosing) {
      setState(() => _notice = '正在完成当前文件或提交状态，请稍候再离开。');
      return false;
    }
    if (!_hadInput && _queue.items.isEmpty) return true;
    if (_retired) {
      try {
        await _saveDraft();
        return true;
      } catch (error) {
        if (mounted) setState(() => _storageError = error);
        return false;
      }
    }
    final decision = await showDialog<String>(
      context: context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(_queue.hasUnknown ? '保留原发布记录后离开？' : '保存发布队列？'),
        content: Text(
          _queue.hasUnknown
              ? '待核对项目不能丢弃或换编号重发。离开前将保留原目标、原编号和阶段；文件需要重新选择。'
              : '可保存当前目标、版本与队列进度。草稿不包含文件内容、路径或认证材料。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, 'stay'),
            child: const Text('留在本页'),
          ),
          if (!_queue.hasUnknown)
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'discard'),
              child: const Text('不保存'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, 'save'),
            child: Text(_queue.hasUnknown ? '保存原记录并离开' : '保存草稿'),
          ),
        ],
      ),
    );
    if (!mounted || decision == null || decision == 'stay') return false;
    if (decision == 'discard' && !_queue.hasUnknown && _current) {
      _draftTimer?.cancel();
      _discarding = true;
      try {
        await _draft!.discard(isCurrent: () => _current && !_queue.hasUnknown);
        _discarded = true;
        _exitAllowed = true;
        return true;
      } catch (error) {
        if (mounted) setState(() => _storageError = error);
        return false;
      } finally {
        _discarding = false;
      }
    }
    try {
      await _saveDraft();
      _exitAllowed = true;
      return true;
    } catch (error) {
      if (mounted) setState(() => _storageError = error);
      return false;
    }
  }

  @override
  void dispose() {
    _draftTimer?.cancel();
    FormDraftNavigation.unregister(this);
    _queue.removeListener(_queueChanged);
    if (!_discarded && (_hadInput || _queue.items.isNotEmpty)) {
      unawaited(_saveDraft().catchError((Object _) {}));
    }
    _queue.dispose();
    for (final controller in [_version, _build, _notes, _store]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(clientReleasePublisherProvider);
    ref.watch(apiClientProvider);
    ref.watch(sensitiveReadBoundaryProvider);
    ref.listen(clientReleasePublisherProvider, (_, next) {
      if (next != _owner) _retire();
    });
    ref.listen(apiClientProvider, (_, next) {
      if (!identical(next, _api)) _retire();
    });
    ref.listen(sensitiveReadBoundaryProvider, (_, next) {
      if (next != _boundary) _retire();
    });
    final theme = Theme.of(context);
    final body = !_current
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 32),
                  const SizedBox(height: UtenSpacing.s12),
                  const Text(
                    '发布身份、权限或服务器已变化，请重新进入页面。原发布元数据只保留在原账号下。',
                    textAlign: TextAlign.center,
                  ),
                  if (_storageError != null) ...[
                    const SizedBox(height: UtenSpacing.s12),
                    const Text('原元数据尚未保全，请恢复本机存储后重试。'),
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: () async {
                        try {
                          await _saveDraft();
                        } catch (_) {}
                      },
                      child: const Text('重试保全'),
                    ),
                  ],
                ],
              ),
            ),
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final summary = _summary();
              final notice =
                  _notice != null ||
                      _storageError != null ||
                      _queue.error != null
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: UtenSpacing.s12,
                      ),
                      child: Text(
                        _storageError != null
                            ? '本机草稿尚未保存，请保留此页并重试；未保全的项目不会继续发送。'
                            : _notice ?? _queue.error!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _storageError != null
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : const SizedBox.shrink();
              return UtenContentContainer(
                selectable: false,
                child: constraints.maxWidth >= 1120
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _contextPanel(),
                          notice,
                          const SizedBox(height: UtenSpacing.s16),
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(child: _workPanel()),
                                const SizedBox(width: UtenSpacing.s24),
                                SizedBox(
                                  width: 300,
                                  child: SingleChildScrollView(child: summary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      )
                    : SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _contextPanel(),
                            notice,
                            const SizedBox(height: UtenSpacing.s16),
                            SizedBox(
                              height: (constraints.maxHeight * .75)
                                  .clamp(460, 720)
                                  .toDouble(),
                              child: _workPanel(),
                            ),
                            const SizedBox(height: UtenSpacing.s24),
                            summary,
                            const SizedBox(height: UtenSpacing.s24),
                          ],
                        ),
                      ),
              );
            },
          );
    return PopScope(
      canPop: _exitAllowed,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (await _confirmLeave() && mounted) {
          setState(() => _exitAllowed = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) Navigator.of(context).pop(result);
          });
        }
      },
      child: Scaffold(
        appBar: const UtenAppBar(
          title: '客户端发布工作台',
          subtitle: '选择文件、核对目标与版本，逐项上传并保留明确结果',
          showBackButton: true,
        ),
        body: _ready || !_current
            ? body
            : Center(
                child: _storageError == null
                    ? const CircularProgressIndicator()
                    : UtenButton(
                        onPressed: _initialize,
                        child: const Text('重试初始化草稿保护'),
                      ),
              ),
      ),
    );
  }

  Widget _contextPanel() {
    final theme = Theme.of(context);
    final enabled = _ready && !_queue.busy && !_choosing;
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: UtenSpacing.s16,
            runSpacing: UtenSpacing.s4,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Text('版本与适用设备', style: theme.textTheme.titleMedium),
              Text(
                '新增项目默认值',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _TargetFields(
            metadata: _context,
            enabled: enabled,
            onChanged: _setTarget,
            version: _version,
            buildController: _build,
          ),
          const SizedBox(height: UtenSpacing.s12),
          TextField(
            controller: _notes,
            enabled: enabled,
            minLines: 1,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '发布说明',
              hintText: '本次更新内容与适用范围',
            ),
          ),
          if (const {'ios', 'macos'}.contains(_context.platform) ||
              _context.storeUrl.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _store,
              enabled: enabled,
              decoration: const InputDecoration(labelText: '官方商店链接'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _queuePanel() {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.tableAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '文件队列 · ${_queue.items.length}',
                  style: theme.textTheme.titleMedium,
                ),
                UtenButton(
                  type: UtenButtonType.secondary,
                  icon: Icons.add_rounded,
                  onPressed: _queue.busy || _choosing
                      ? null
                      : () => _pick(false),
                  child: const Text('添加单个文件'),
                ),
                UtenButton(
                  type: UtenButtonType.secondary,
                  icon: Icons.playlist_add_rounded,
                  onPressed: _queue.busy || _choosing
                      ? null
                      : () => _pick(true),
                  child: const Text('批量添加'),
                ),
                if (const {'ios', 'macos'}.contains(_context.platform))
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _queue.busy
                        ? null
                        : () {
                            _hadInput = true;
                            _queue.addStore(_context);
                          },
                    child: const Text('添加商店链接'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _queue.items.isEmpty
                ? SingleChildScrollView(
                    child: Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.upload_file_outlined,
                            size: 40,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Text(
                            '把同一版本的文件集中在这里',
                            style: theme.textTheme.titleMedium,
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          const Text(
                            'Windows 选择 Setup.exe 和更新 ZIP。请核对每项版本和适用设备，系统会校验文件内容。',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    itemCount: _queue.items.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final item = _queue.items[index];
                      return _QueueRow(
                        key: ValueKey(item.localId),
                        item: item,
                        busy: _queue.busy || _choosing,
                        onEdit: (metadata) {
                          _hadInput = true;
                          _queue.edit(item, metadata);
                        },
                        onReselect: () => _pick(false, item),
                        onRead: () => _queue.reconcile(item),
                        onRemove: () => _queue.remove(item),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _queue.busy
                        ? '逐项处理，原编号和结果持续保全…'
                        : '已确认 ${_queue.confirmedCount} 项；失败与待核对项目保留原记录。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                UtenButton(
                  key: const ValueKey('client-release-publish-batch'),
                  icon: _queue.busy ? null : Icons.publish_rounded,
                  onPressed:
                      !_ready ||
                          _queue.busy ||
                          _choosing ||
                          _queue.items.isEmpty
                      ? null
                      : _queue.run,
                  child: Text(_queue.busy ? '正在处理' : '上传并发布'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _workPanel() => DefaultTabController(
    length: 2,
    child: Column(
      children: [
        const TabBar(
          tabs: [
            Tab(text: '发布队列'),
            Tab(text: '发布记录'),
          ],
        ),
        const SizedBox(height: UtenSpacing.s12),
        Expanded(child: TabBarView(children: [_queuePanel(), _ledger()])),
      ],
    ),
  );
  Widget _ledger() {
    final theme = Theme.of(context);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.tableAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '原文件的发布与撤回结果',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: '刷新发布记录',
                  onPressed: _queue.busy
                      ? null
                      : () async {
                          try {
                            await _queue.load();
                          } catch (_) {
                            if (_current) {
                              setState(() => _notice = '发布记录刷新未完成，请稍后重试。');
                            }
                          }
                        },
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _queue.releases.isEmpty
                ? const Center(child: Text('尚无可显示的发布记录。'))
                : ListView.separated(
                    itemCount: _queue.releases.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final record = _queue.releases[index],
                          pending =
                              _queue.withdrawals[_queue.releases[index].id];
                      return Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              record.fileName ?? record.version,
                              style: theme.textTheme.titleSmall,
                            ),
                            const SizedBox(height: UtenSpacing.s6),
                            Text(
                              '${_targetLabel(ClientReleasePublishMetadata(platform: record.platform, runtimeFamily: record.runtimeFamily, architecture: record.architecture))} · ${record.version} + ${record.buildNumber} · ${record.packageKind == 'installer' ? '安装包' : '更新包'}',
                            ),
                            Wrap(
                              spacing: UtenSpacing.s8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  pending == ClientReleaseWithdrawState.unknown
                                      ? '撤回结果待核对'
                                      : record.state == 'PUBLISHED'
                                      ? '已发布'
                                      : record.state == 'WITHDRAWN'
                                      ? '已撤回'
                                      : '草稿',
                                ),
                                if (pending ==
                                    ClientReleaseWithdrawState.unknown)
                                  TextButton(
                                    onPressed: _queue.busy
                                        ? null
                                        : () => _queue.reconcileWithdrawal(
                                            record.id,
                                          ),
                                    child: const Text('核对原撤回状态'),
                                  )
                                else if (record.state == 'PUBLISHED')
                                  TextButton(
                                    onPressed: _queue.busy
                                        ? null
                                        : () async {
                                            final confirmed =
                                                await showDialog<bool>(
                                                  context: context,
                                                  builder: (dialogContext) =>
                                                      UtenAlertDialog(
                                                        title: const Text(
                                                          '撤回这个版本？',
                                                        ),
                                                        content: const Text(
                                                          '撤回后该文件不再提供下载。已发布的其他组合与原审计记录保留。',
                                                        ),
                                                        actions: [
                                                          TextButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  dialogContext,
                                                                  false,
                                                                ),
                                                            child: const Text(
                                                              '取消',
                                                            ),
                                                          ),
                                                          FilledButton(
                                                            onPressed: () =>
                                                                Navigator.pop(
                                                                  dialogContext,
                                                                  true,
                                                                ),
                                                            child: const Text(
                                                              '确认撤回',
                                                            ),
                                                          ),
                                                        ],
                                                      ),
                                                );
                                            if (confirmed == true && _current) {
                                              await _queue.withdraw(record);
                                            }
                                          },
                                    child: const Text('撤回'),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _summary() {
    final theme = Theme.of(context);
    final records = <String, ClientRelease>{
      for (final release in _queue.releases) release.id: release,
      for (final item in _queue.items)
        if (item.publishedRelease case final ClientRelease release)
          release.id: release,
    };
    final groups = <String, Set<String>>{};
    final groupLabels = <String, String>{};
    for (final release in records.values) {
      if (release.platform != 'windows' ||
          release.state != 'PUBLISHED' ||
          release.sha256.isEmpty ||
          release.sizeBytes <= 0) {
        continue;
      }
      final group =
          '${release.runtimeFamily}/${release.architecture}/${release.version}/${release.buildNumber}';
      groups.putIfAbsent(group, () => {}).add(release.packageKind);
      groupLabels[group] =
          '${_targetLabel(ClientReleasePublishMetadata(platform: release.platform, runtimeFamily: release.runtimeFamily, architecture: release.architecture))}\n${release.version} · 构建 ${release.buildNumber}';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('完整配对', style: theme.textTheme.titleMedium),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '新发布的 Windows 组：同适用设备、版本和构建号的 Setup 与 ZIP 都发布后，才开放该组下载。历史版本沿原发布方式保留。',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: UtenSpacing.s16),
        if (groups.isEmpty)
          Text('当前尚无已确认的 Windows 完整组。', style: theme.textTheme.bodySmall),
        for (final group in groups.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  group.value.containsAll({'installer', 'update'})
                      ? Icons.check_circle_outline_rounded
                      : Icons.pending_outlined,
                  size: 20,
                  color: group.value.containsAll({'installer', 'update'})
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '${groupLabels[group.key]}\n${group.value.containsAll({'installer', 'update'}) ? 'Setup + ZIP 已齐' : '等待另一份配对文件'}',
                  ),
                ),
              ],
            ),
          ),
        const Divider(height: UtenSpacing.s32),
        Text('发布摘要', style: theme.textTheme.titleMedium),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '已确认 ${_queue.confirmedCount} 项\n已撤回 ${_queue.items.where((item) => item.stage == ClientReleaseQueueStage.withdrawn).length} 项\n待核对 ${_queue.items.where((item) => item.uncertain).length} 项\n其余 ${_queue.items.where((item) => !item.terminal && !item.uncertain).length} 项',
        ),
        const SizedBox(height: UtenSpacing.s16),
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: _queue.busy
              ? null
              : () async {
                  try {
                    await _saveDraft();
                    if (mounted) {
                      setState(
                        () => _notice = '发布元数据已保全。重新进入时先核对原状态，再重选需要的文件。',
                      );
                    }
                  } catch (error) {
                    if (mounted) setState(() => _storageError = error);
                  }
                },
          child: const Text('保存发布草稿'),
        ),
      ],
    );
  }

  static String _human(Object error) => error is StateError
      ? error.message.toString()
      : error is FormatException
      ? error.message
      : '本次操作暂未完成，请保留原记录后重试。';
}

String _targetLabel(ClientReleasePublishMetadata metadata) {
  final platform = SoftwareDownloadPlatform.fromName(metadata.platform);
  return platform == null
      ? '适用设备待核对'
      : SoftwareDownloadTarget(
          platform: platform,
          runtimeFamily: metadata.runtimeFamily,
          architecture: metadata.architecture,
        ).displayLabel;
}

class _QueueRow extends StatefulWidget {
  const _QueueRow({
    super.key,
    required this.item,
    required this.busy,
    required this.onEdit,
    required this.onReselect,
    required this.onRead,
    required this.onRemove,
  });
  final ClientReleaseQueueItem item;
  final bool busy;
  final ValueChanged<ClientReleasePublishMetadata> onEdit;
  final VoidCallback onReselect, onRead, onRemove;
  @override
  State<_QueueRow> createState() => _QueueRowState();
}

class _QueueRowState extends State<_QueueRow> {
  bool expanded = false;
  late final version = TextEditingController(
        text: widget.item.metadata.version,
      ),
      buildText = TextEditingController(text: widget.item.metadata.buildNumber);
  @override
  void dispose() {
    version.dispose();
    buildText.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item, theme = Theme.of(context);
    final stage = switch (item.stage) {
      ClientReleaseQueueStage.needsFile => '请重选原文件',
      ClientReleaseQueueStage.ready => '待校验',
      ClientReleaseQueueStage.validating => '读取与校验',
      ClientReleaseQueueStage.prepared => '已准备草稿',
      ClientReleaseQueueStage.uploading => '正在上传',
      ClientReleaseQueueStage.uploaded => '文件已确认',
      ClientReleaseQueueStage.publishing => '正在发布',
      ClientReleaseQueueStage.published => '已确认发布',
      ClientReleaseQueueStage.withdrawn => '已撤回',
      ClientReleaseQueueStage.rejected => '未完成',
      ClientReleaseQueueStage.unknown => '结果待核对',
    };
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                item.published
                    ? Icons.check_circle_outline_rounded
                    : item.uncertain
                    ? Icons.help_outline_rounded
                    : Icons.insert_drive_file_outlined,
                color: item.published
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  item.fileName ?? '官方商店链接',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Flexible(
                child: Text(
                  item.publishedRelease?.state == 'WITHDRAWN'
                      ? '已撤回'
                      : item.retentionPending
                      ? '已发布，待保留检查'
                      : stage,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '${_targetLabel(item.metadata)} · ${item.metadata.packageKind == 'installer'
                ? 'Setup 安装包'
                : item.metadata.isStore
                ? '商店链接'
                : '更新包'}'
            ' · ${item.metadata.version.isEmpty ? '未填版本' : item.metadata.version} + ${item.metadata.buildNumber.isEmpty ? '未填构建号' : item.metadata.buildNumber}'
            '${item.sizeBytes > 0 ? ' · ${(item.sizeBytes / 1048576).toStringAsFixed(1)} MiB' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (item.stage == ClientReleaseQueueStage.uploading)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s12),
              child: LinearProgressIndicator(value: item.progress),
            ),
          if (item.error != null)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                item.error!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Wrap(
            spacing: UtenSpacing.s8,
            children: [
              TextButton(
                onPressed: item.frozen
                    ? null
                    : () => setState(() => expanded = !expanded),
                child: Text(expanded ? '收起目标' : '核对/编辑目标'),
              ),
              if (item.needsFile || !item.frozen)
                TextButton(
                  onPressed: widget.busy || item.uncertain
                      ? null
                      : widget.onReselect,
                  child: const Text('重选文件'),
                ),
              if (item.requestId != null && !item.terminal)
                TextButton(
                  onPressed: widget.busy ? null : widget.onRead,
                  child: const Text('核对原状态'),
                ),
              if (!item.frozen ||
                  const {
                    ClientReleaseQueueStage.rejected,
                    ClientReleaseQueueStage.withdrawn,
                  }.contains(item.stage))
                TextButton(
                  onPressed: widget.busy ? null : widget.onRemove,
                  child: const Text('移出队列'),
                ),
            ],
          ),
          if (expanded && !item.frozen)
            _TargetFields(
              metadata: item.metadata,
              enabled: !widget.busy,
              onChanged: widget.onEdit,
              version: version,
              buildController: buildText,
              onVersion: (text) =>
                  widget.onEdit(item.metadata.copyWith(version: text)),
              onBuild: (text) =>
                  widget.onEdit(item.metadata.copyWith(buildNumber: text)),
            ),
        ],
      ),
    );
  }
}

class _TargetFields extends StatelessWidget {
  const _TargetFields({
    required this.metadata,
    required this.enabled,
    required this.onChanged,
    required this.version,
    required this.buildController,
    this.onVersion,
    this.onBuild,
  });
  final ClientReleasePublishMetadata metadata;
  final bool enabled;
  final ValueChanged<ClientReleasePublishMetadata> onChanged;
  final TextEditingController version, buildController;
  final ValueChanged<String>? onVersion, onBuild;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _fields(context, constraints.maxWidth),
  );
  Widget _fields(BuildContext context, double availableWidth) {
    final fieldScale = MediaQuery.textScalerOf(context).scale(1);
    double width(double base) => (base * fieldScale).clamp(0, availableWidth);
    String optionLabel(String label, String option) => label == '客户端类型'
        ? windowsRuntimeLabel(option)
        : label == '架构'
        ? softwareArchitectureLabel(option)
        : label == '系统'
        ? SoftwareDownloadPlatform.fromName(option)?.label ?? option
        : label == '包类型'
        ? option == 'installer'
              ? 'Setup 安装包'
              : '更新 ZIP'
        : option;
    final platform = SoftwareDownloadPlatform.fromName(metadata.platform);
    final architectures = platform == null
        ? const <String>[]
        : softwareDownloadArchitectures(
            platform,
            runtimeFamily: metadata.runtimeFamily,
          );
    Widget select(
      String label,
      String value,
      List<String> values,
      ValueChanged<String> changed,
    ) => SizedBox(
      width: width(
        label == '客户端类型'
            ? 270
            : label == '包类型'
            ? 190
            : 150,
      ),
      child: UtenDropdownScrollScope(
        nativeDropdown: true,
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label-$value'),
          initialValue: values.contains(value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            for (final option in values)
              DropdownMenuItem(
                value: option,
                child: Tooltip(
                  message: optionLabel(label, option),
                  child: Text(
                    optionLabel(label, option),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
          onChanged: enabled
              ? (value) {
                  if (value != null) changed(value);
                }
              : null,
        ),
      ),
    );
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        select(
          '系统',
          metadata.platform,
          const ['windows', 'android', 'ios', 'macos'],
          (platform) => onChanged(
            metadata.copyWith(
              platform: platform,
              runtimeFamily: ClientRuntimeFamily.flutter,
              architecture: platform == 'windows' ? 'x64' : 'universal',
              packageKind: 'update',
              storeUrl: '',
            ),
          ),
        ),
        if (metadata.platform == 'windows')
          select(
            '客户端类型',
            metadata.runtimeFamily,
            const [ClientRuntimeFamily.flutter, ClientRuntimeFamily.wpfLegacy],
            (family) => onChanged(
              metadata.copyWith(
                runtimeFamily: family,
                architecture:
                    softwareDownloadArchitectures(
                      SoftwareDownloadPlatform.windows,
                      runtimeFamily: family,
                    ).contains(metadata.architecture)
                    ? metadata.architecture
                    : 'x64',
              ),
            ),
          ),
        select(
          '架构',
          metadata.architecture,
          architectures,
          (architecture) =>
              onChanged(metadata.copyWith(architecture: architecture)),
        ),
        if (metadata.platform == 'windows')
          select(
            '包类型',
            metadata.packageKind,
            const ['installer', 'update'],
            (kind) => onChanged(metadata.copyWith(packageKind: kind)),
          ),
        SizedBox(
          width: width(150),
          child: TextField(
            controller: version,
            enabled: enabled,
            onChanged: onVersion,
            decoration: const InputDecoration(
              labelText: '版本',
              hintText: '2.5.34',
            ),
          ),
        ),
        SizedBox(
          width: width(150),
          child: TextField(
            controller: buildController,
            enabled: enabled,
            onChanged: onBuild,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: '构建号',
              hintText: '2534',
            ),
          ),
        ),
      ],
    );
  }
}
