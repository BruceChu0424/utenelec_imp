import '../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/cards/uten_card.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/inputs/uten_field_hint_icon.dart';
import '../../components/layout/uten_section_header.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/responsive/dialog_size.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/uten_notify.dart';
import '../../shared/providers/authenticated_scope_provider.dart';
import 'client_release.dart';
import 'client_release_access.dart';

class ClientReleasePublishDialog extends ConsumerStatefulWidget {
  const ClientReleasePublishDialog({super.key, this.packageKind = 'update'});

  /// Retained for existing callers. Windows always shows both package areas.
  final String packageKind;
  @override
  ConsumerState<ClientReleasePublishDialog> createState() => _PublishState();
}

class _PackageIntent {
  Uint8List? bytes;
  String? fileName, requestId, result;
  bool published = false, failed = false;

  void reset({bool clearFile = false}) {
    requestId = result = null;
    published = failed = false;
    if (clearFile) bytes = null;
    if (bytes == null) fileName = null;
  }
}

class _PackageSelection {
  _PackageSelection(this.kind, this.intent)
    : bytes = intent.bytes,
      fileName = intent.fileName;

  final String kind;
  final _PackageIntent intent;
  final Uint8List? bytes;
  final String? fileName;
}

class _PublishState extends ConsumerState<ClientReleasePublishDialog> {
  final _version = TextEditingController();
  final _build = TextEditingController();
  final _notes = TextEditingController();
  final _store = TextEditingController();
  String _platform = 'windows', _architecture = 'x64';
  final _packages = {'installer': _PackageIntent(), 'update': _PackageIntent()};
  Object? _metadata;
  String? _activeKind;
  bool _choosing = false;
  bool _busy = false;
  bool _withdrawing = false;
  double _progress = 0;
  int _publishGeneration = 0;
  List<ClientRelease> _releases = [];
  late final ApiClient _api;
  late final AuthenticatedScope? _owner;
  bool _invalidated = false;
  bool get _isStore => {'ios', 'macos'}.contains(_platform);
  bool get _current =>
      mounted &&
      !_invalidated &&
      _owner != null &&
      identical(_api, ref.read(apiClientProvider)) &&
      ref.read(clientReleasePublisherProvider) == _owner;

  @override
  void initState() {
    super.initState();
    _metadata = _metadataKey();
    _api = ref.read(apiClientProvider);
    _owner = ref.read(clientReleasePublisherProvider);
    for (final controller in [_version, _build, _notes, _store]) {
      controller.addListener(_newIntent);
    }
    _load();
  }

  void _invalidatePublisher() {
    if (_invalidated) return;
    _invalidated = true;
    for (final intent in _packages.values) {
      intent.reset(clearFile: true);
    }
    final route = ModalRoute.of(context);
    // Remove only this publishing dialog, including while a request is pending.
    // Regranting permission must not resume the invalidated draft operation.
    if (route is DialogRoute) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  Object _metadataKey() => (
    _platform,
    _architecture,
    _version.text.trim(),
    int.tryParse(_build.text.trim()) ?? _build.text.trim(),
    _notes.text.trim(),
    _store.text.trim(),
  );

  void _newIntent() {
    final next = _metadataKey();
    if (_busy || next == _metadata) return;
    setState(() {
      _metadata = next;
      for (final intent in _packages.values) {
        intent.reset();
      }
    });
  }

  void _resetFiles() {
    for (final intent in _packages.values) {
      intent.reset(clearFile: true);
    }
    _metadata = _metadataKey();
  }

  Future<void> _load({AuthenticatedRequestScope? requestScope}) async {
    try {
      final scope =
          requestScope ??
          await _api.captureRequestScope(isCurrent: () => _current);
      final items = await scope.run(
        () => _api.getList('/admin/client-releases'),
      );
      if (_current) {
        setState(() => _releases = items.map(ClientRelease.fromJson).toList());
      }
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    }
  }

  Future<void> _choose([String kind = 'update']) async {
    if (_busy || !_current) return;
    final intent = _packages[kind]!;
    setState(() {
      _busy = true;
      _choosing = true;
      _activeKind = kind;
      _progress = 0;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          _platform == 'windows'
              ? kind == 'installer'
                    ? 'exe'
                    : 'zip'
              : 'apk',
        ],
        withData: true,
      );
      if (!mounted || !_current || result == null) return;
      final file = result.files.single;
      if (file.size == 0 || file.size > 536870912 || file.bytes == null) {
        UtenNotify.error(
          context,
          AppLocalizations.of(context).clientUpdatePublishInvalid,
        );
        return;
      }
      setState(() {
        intent.bytes = file.bytes;
        intent.fileName = file.name;
        intent.reset();
      });
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = _choosing = false;
          _activeKind = null;
        });
      }
    }
  }

  Future<void> _publish() async {
    if (_busy || !_current) return;
    if (_platform != 'windows' && _packages['update']!.published) return;
    final store = _isStore;
    final selections = [
      for (final kind
          in _platform == 'windows' ? ['installer', 'update'] : ['update'])
        if (!_packages[kind]!.published &&
            (store || _packages[kind]!.bytes != null))
          _PackageSelection(kind, _packages[kind]!),
    ];
    final l10n = AppLocalizations.of(context);
    final build = int.tryParse(_build.text.trim());
    final version = _version.text.trim();
    final storeRelease = ClientRelease(
      id: '',
      platform: _platform,
      architecture: _architecture,
      version: version,
      buildNumber: build ?? 0,
      releaseNotes: '',
      installMode: 'store',
      storeUrl: _store.text.trim(),
    );
    if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        build == null ||
        build <= 0 ||
        build > 2147483647 ||
        selections.isEmpty ||
        (store && storeRelease.trustedStoreUri == null)) {
      UtenNotify.error(context, l10n.clientUpdatePublishInvalid);
      return;
    }
    final metadataKey = _metadataKey();
    final generation = ++_publishGeneration;
    final metadata = Map<String, Object>.unmodifiable({
      'platform': _platform,
      'architecture': _architecture,
      'version': version,
      'buildNumber': build,
      'releaseNotes': _notes.text.trim(),
      'mandatory': false,
      if (store) 'storeUrl': _store.text.trim(),
    });
    bool current() =>
        _current &&
        generation == _publishGeneration &&
        _metadataKey() == metadataKey;
    setState(() {
      _busy = true;
      _activeKind = selections.first.kind;
      _progress = 0;
    });
    try {
      // One click owns one immutable selection and authentication scope. Files
      // commit independently; a failed item does not erase another receipt.
      final scope = await _api.captureRequestScope(isCurrent: current);
      for (final selection in selections) {
        if (!current()) break;
        await scope.verify();
        final intent = selection.intent;
        setState(() {
          _activeKind = selection.kind;
          _progress = 0;
          intent.result = null;
          intent.failed = false;
        });
        try {
          await _publishPackage(
            selection,
            scope: scope,
            metadata: metadata,
            store: store,
            isCurrent: current,
          );
        } catch (e) {
          if (!mounted || !current()) break;
          setState(() {
            intent.result = '此文件尚未确认发布，可重试；其他文件的发布结果保留。';
            intent.failed = true;
          });
          UtenNotify.apiError(context, e);
        }
      }
      if (current()) await _load(requestScope: scope);
    } catch (e) {
      if (mounted && current()) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _activeKind = null;
        });
        _newIntent();
      }
    }
  }

  Future<void> _publishPackage(
    _PackageSelection selection, {
    required AuthenticatedRequestScope scope,
    required Map<String, Object> metadata,
    required bool store,
    required bool Function() isCurrent,
  }) async {
    final kind = selection.kind;
    final intent = selection.intent;
    final bytes = selection.bytes;
    final expectedSha = store ? null : sha256.convert(bytes!).toString();
    // The same intent survives a lost create/upload/publish response. The
    // server's idempotent create recovers its durable state on retry.
    intent.requestId ??= const Uuid().v4();
    final draft = await scope.run(
      () => _api.post(
        '/admin/client-releases',
        body: {
          'requestId': intent.requestId,
          ...metadata,
          if (metadata['platform'] == 'windows') 'packageKind': kind,
          if (!store) 'fileName': selection.fileName,
          if (!store) 'expectedSha256': expectedSha,
        },
      ),
    );
    final id = draft['id'] as String;
    final alreadyPublished = draft['state'] == 'PUBLISHED';
    if (!store && !alreadyPublished && draft['sha256'] != expectedSha) {
      await scope.run(
        () => _api.uploadClientPackage(
          '/admin/client-releases/$id/package',
          bytes!,
          onProgress: (sent, total) {
            if (isCurrent() &&
                _busy &&
                !_choosing &&
                !_withdrawing &&
                _activeKind == kind &&
                identical(_packages[kind], intent) &&
                total > 0) {
              setState(() => _progress = sent / total);
            }
          },
        ),
      );
    }
    // A Windows publication may commit before retaining its latest pair
    // finishes. Retry that work with the same release, without uploading again.
    if (metadata['platform'] == 'windows' || !alreadyPublished) {
      await scope.run(() => _api.post('/admin/client-releases/$id/publish'));
    }
    if (!mounted || !isCurrent()) return;
    setState(() {
      intent.result = AppLocalizations.of(context).clientUpdatePublished;
      intent.published = true;
      intent.bytes = null;
    });
  }

  Future<void> _withdraw(ClientRelease release) async {
    if (_busy || !_current) return;
    final l10n = AppLocalizations.of(context);
    setState(() {
      _busy = true;
      _withdrawing = true;
    });
    try {
      final scope = await _api.captureRequestScope(isCurrent: () => _current);
      if (!mounted || !_current) return;
      final confirmed = await UtenNotify.alert(
        context,
        title: l10n.clientUpdateWithdraw,
        message: l10n.clientUpdateWithdrawConfirm,
        confirmLabel: l10n.clientUpdateWithdraw,
        cancelLabel: l10n.clientUpdateClose,
      );
      if (!_current || confirmed != true) return;
      await scope.run(
        () => _api.post('/admin/client-releases/${release.id}/withdraw'),
      );
      await _load();
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _withdrawing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final controller in [_version, _build, _notes, _store]) {
      controller.dispose();
    }
    super.dispose();
  }

  Widget _packageResult(String kind) {
    final intent = _packages[kind]!;
    if (intent.result == null) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      key: ValueKey('client-release-result-$kind'),
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: Semantics(
        liveRegion: true,
        child: Text(
          intent.result!,
          style: TextStyle(
            color: intent.failed ? colors.error : colors.primary,
          ),
        ),
      ),
    );
  }

  Widget _packageArea(String kind) {
    final installer = kind == 'installer';
    final intent = _packages[kind]!;
    final active = _busy && _activeKind == kind;
    final l10n = AppLocalizations.of(context);
    return UtenCard(
      key: ValueKey('client-release-area-$kind'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenSectionHeader(
              title: installer ? 'Windows 安装程序（Setup.exe）' : 'Windows 更新包（ZIP）',
              info: installer
                  ? '放在“软件下载”页面，供员工首次下载安装。'
                  : '已安装的客户端自动获取，沿用原安装位置更新。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              key: ValueKey('client-release-choose-$kind'),
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : () => _choose(kind),
              child: Text(
                intent.fileName ??
                    (installer ? '选择完整客户端' : l10n.clientUpdateChooseFile),
              ),
            ),
            if (active) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(_choosing ? '正在读取所选文件' : l10n.clientUpdatePublishing),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ],
            _packageResult(kind),
          ],
        ),
      ),
    );
  }

  Widget _windowsPackages() {
    final sideBySide =
        utenDialogWidth(context, 820) >= 720 &&
        MediaQuery.textScalerOf(context).scale(14) <= 21;
    if (sideBySide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _packageArea('installer')),
          const SizedBox(width: UtenSpacing.s16),
          Expanded(child: _packageArea('update')),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _packageArea('installer'),
        const SizedBox(height: UtenSpacing.s16),
        _packageArea('update'),
      ],
    );
  }

  Widget _publishDialog({
    required Widget title,
    required Widget content,
    required List<Widget> actions,
  }) {
    if (_platform != 'windows') {
      return UtenAlertDialog(
        maxWidth: 820,
        title: title,
        content: content,
        actions: actions,
      );
    }
    final theme = Theme.of(context);
    // This is a long publishing workspace. Keep its actions fixed even in the
    // short-window layout where an alert would scroll its whole surface.
    return UtenDialogFrame(
      maxWidth: 820,
      fillHeight: true,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              namesRoute: true,
              child: DefaultTextStyle.merge(
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                child: title,
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            Expanded(
              child: SingleChildScrollView(
                child: DefaultTextStyle.merge(
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.55,
                  ),
                  child: content,
                ),
              ),
            ),
            const SizedBox(height: UtenSpacing.s16),
            OverflowBar(
              alignment: MainAxisAlignment.center,
              overflowAlignment: OverflowBarAlignment.center,
              spacing: UtenSpacing.s12,
              overflowSpacing: UtenSpacing.s8,
              children: actions,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(clientReleasePublisherProvider);
    ref.watch(apiClientProvider);
    ref.listen(clientReleasePublisherProvider, (_, next) {
      if (next != _owner) _invalidatePublisher();
    });
    ref.listen(apiClientProvider, (_, next) {
      if (!identical(next, _api)) _invalidatePublisher();
    });
    if (!_current) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: _publishDialog(
        title: UtenSectionHeader(
          title: l10n.clientUpdatePublishTitle,
          info: _platform == 'windows'
              ? '填写版本信息并选择要发布的文件，再点击下方“上传并发布”。每个文件分别显示进度和结果，重试会继续未确认的文件。'
              : l10n.clientUpdatePublishHint,
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            UtenDropdownScrollScope(
              nativeDropdown: true,
              child: DropdownButtonFormField<String>(
                initialValue: _platform,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.clientUpdatePlatform,
                ),
                items: [
                  for (final name in ['windows', 'android', 'ios', 'macos'])
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _platform = value!;
                        _architecture = value == 'windows'
                            ? 'x64'
                            : 'universal';
                        _resetFiles();
                      }),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            UtenDropdownScrollScope(
              nativeDropdown: true,
              child: DropdownButtonFormField<String>(
                key: ValueKey(
                  'client-release-architecture-$_platform-$_architecture',
                ),
                initialValue: _architecture,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.clientUpdateArchitecture,
                ),
                items: [
                  for (final name
                      in _platform == 'windows'
                          ? ['x64', 'arm64', 'x86']
                          : _platform == 'android'
                          ? ['universal', 'arm64', 'armeabi-v7a', 'x64']
                          : ['universal'])
                    DropdownMenuItem(value: name, child: Text(name)),
                ],
                onChanged: _busy
                    ? null
                    : (value) => setState(() {
                        _architecture = value!;
                        _resetFiles();
                      }),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _version,
              enabled: !_busy,
              decoration: InputDecoration(labelText: l10n.clientUpdateVersion),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _build,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l10n.clientUpdateBuild),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _notes,
              enabled: !_busy,
              minLines: 3,
              maxLines: 6,
              maxLength: 10000,
              decoration: InputDecoration(labelText: l10n.clientUpdateNotes),
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (_platform == 'windows')
              _windowsPackages()
            else if (_isStore)
              TextField(
                controller: _store,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.clientUpdateStoreUrl,
                ),
              )
            else
              Row(
                children: [
                  Flexible(
                    child: UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : () => _choose(),
                      child: Text(
                        _packages['update']!.fileName ??
                            l10n.clientUpdateChooseFile,
                      ),
                    ),
                  ),
                  UtenFieldHintIcon(
                    info: l10n.clientUpdatePackageHint,
                    dense: true,
                  ),
                ],
              ),
            if (_busy && (_platform != 'windows' || _withdrawing)) ...[
              const SizedBox(height: UtenSpacing.s16),
              Text(
                _withdrawing
                    ? l10n.clientUpdateWithdraw
                    : l10n.clientUpdatePublishing,
              ),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ],
            if (_platform != 'windows') _packageResult('update'),
            if (_releases.where((r) => r.state == 'PUBLISHED').isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s24),
              Text(
                l10n.clientUpdateReleaseList,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              for (final release in _releases.where(
                (r) => r.state == 'PUBLISHED',
              ))
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s12),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: UtenSpacing.s12,
                    children: [
                      Text(
                        '${release.platform} ${release.architecture}  ${release.version}+${release.buildNumber}${release.platform == 'windows'
                            ? release.packageKind == 'installer'
                                  ? ' · Setup.exe'
                                  : ' · ZIP 更新包'
                            : ''}',
                      ),
                      UtenButton(
                        type: UtenButtonType.ghost,
                        onPressed: _busy ? null : () => _withdraw(release),
                        child: Text(l10n.clientUpdateWithdraw),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: Text(l10n.clientUpdateClose),
          ),
          UtenButton(
            key: const ValueKey('client-release-publish-batch'),
            isLoading: _platform == 'windows'
                ? _busy && !_choosing && !_withdrawing
                : _busy,
            onPressed:
                _busy ||
                    (_platform == 'windows' &&
                        !_packages.values.any(
                          (intent) => !intent.published && intent.bytes != null,
                        ))
                ? null
                : _publish,
            icon: Icons.publish_rounded,
            child: Text(l10n.clientUpdatePublish),
          ),
        ],
      ),
    );
  }
}
