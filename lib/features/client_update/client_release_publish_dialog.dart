import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/uten_notify.dart';
import '../../shared/auth/permissions.dart';
import '../../shared/providers/session_provider.dart';
import 'client_release.dart';

class ClientReleasePublishDialog extends ConsumerStatefulWidget {
  const ClientReleasePublishDialog({super.key});
  @override
  ConsumerState<ClientReleasePublishDialog> createState() => _PublishState();
}

class _PublishState extends ConsumerState<ClientReleasePublishDialog> {
  final _version = TextEditingController();
  final _build = TextEditingController();
  final _notes = TextEditingController();
  final _store = TextEditingController();
  String _platform = 'windows', _architecture = 'x64';
  Uint8List? _bytes;
  String? _fileName;
  String? _requestId;
  bool _busy = false;
  double _progress = 0;
  String? _result;
  List<ClientRelease> _releases = [];
  late final ApiClient _api;
  late final String? _owner;
  bool get _isStore => {'ios', 'macos'}.contains(_platform);
  bool get _current =>
      mounted &&
      identical(_api, ref.read(apiClientProvider)) &&
      ref.read(sessionProvider).isLoggedIn &&
      ref.read(sessionProvider).user?.id == _owner &&
      !ref.read(sessionProvider).isImpersonating &&
      ref.read(isSuperAdminProvider) &&
      ref.read(currentPermissionsProvider).contains(Perm.authorizationManage);

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _owner = ref.read(sessionProvider).user?.id;
    for (final controller in [_version, _build, _notes, _store]) {
      controller.addListener(_newIntent);
    }
    _load();
  }

  void _newIntent() {
    if (!_busy) {
      _requestId = null;
      _result = null;
    }
  }

  Future<void> _load() async {
    try {
      final scope = await _api.captureRequestScope(isCurrent: () => _current);
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

  Future<void> _choose() async {
    if (_busy || !_current) return;
    setState(() => _busy = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: [_platform == 'windows' ? 'zip' : 'apk'],
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
        _bytes = file.bytes;
        _fileName = file.name;
        _requestId = null;
        _result = null;
      });
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _publish() async {
    if (_busy || !_current) return;
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
        (_isStore ? storeRelease.trustedStoreUri == null : _bytes == null)) {
      UtenNotify.error(context, l10n.clientUpdatePublishInvalid);
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
      _result = null;
    });
    try {
      final scope = await _api.captureRequestScope(isCurrent: () => _current);
      final bytes = _bytes;
      final expectedSha = _isStore ? null : sha256.convert(bytes!).toString();
      // The same intent survives a lost create/upload/publish response. The
      // server's idempotent create recovers its durable state on retry.
      _requestId ??= const Uuid().v4();
      final draft = await scope.run(
        () => _api.post(
          '/admin/client-releases',
          body: {
            'requestId': _requestId,
            'platform': _platform,
            'architecture': _architecture,
            'version': version,
            'buildNumber': build,
            'releaseNotes': _notes.text.trim(),
            'mandatory': false,
            if (!_isStore) 'fileName': _fileName,
            if (!_isStore) 'expectedSha256': expectedSha,
            if (_isStore) 'storeUrl': _store.text.trim(),
          },
        ),
      );
      final id = draft['id'] as String;
      final alreadyPublished = draft['state'] == 'PUBLISHED';
      if (!_isStore && !alreadyPublished && draft['sha256'] != expectedSha) {
        await scope.run(
          () => _api.uploadClientPackage(
            '/admin/client-releases/$id/package',
            bytes!,
            onProgress: (sent, total) {
              if (_current && total > 0) {
                setState(() => _progress = sent / total);
              }
            },
          ),
        );
      }
      if (!alreadyPublished) {
        await scope.run(() => _api.post('/admin/client-releases/$id/publish'));
      }
      if (!_current) return;
      setState(() {
        _result = l10n.clientUpdatePublished;
        _bytes = null;
        _fileName = null;
      });
      await _load();
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _withdraw(ClientRelease release) async {
    if (_busy || !_current) return;
    final l10n = AppLocalizations.of(context);
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
    setState(() => _busy = true);
    try {
      await scope.run(
        () => _api.post('/admin/client-releases/${release.id}/withdraw'),
      );
      await _load();
    } catch (e) {
      if (mounted && _current) UtenNotify.apiError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    for (final controller in [_version, _build, _notes, _store]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PopScope(
      canPop: !_busy,
      child: UtenAlertDialog(
        maxWidth: 680,
        title: Text(l10n.clientUpdatePublishTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.clientUpdatePublishHint),
            const SizedBox(height: UtenSpacing.s16),
            DropdownButtonFormField<String>(
              initialValue: _platform,
              isExpanded: true,
              decoration: InputDecoration(labelText: l10n.clientUpdatePlatform),
              items: [
                for (final name in ['windows', 'android', 'ios', 'macos'])
                  DropdownMenuItem(value: name, child: Text(name)),
              ],
              onChanged: _busy
                  ? null
                  : (value) => setState(() {
                      _platform = value!;
                      _architecture = value == 'windows' ? 'x64' : 'universal';
                      _bytes = null;
                      _fileName = null;
                      _requestId = null;
                      _result = null;
                    }),
            ),
            const SizedBox(height: UtenSpacing.s12),
            DropdownButtonFormField<String>(
              key: ValueKey(_platform),
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
                  : (value) => setState(() => _architecture = value!),
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
            if (_isStore)
              TextField(
                controller: _store,
                enabled: !_busy,
                decoration: InputDecoration(
                  labelText: l10n.clientUpdateStoreUrl,
                ),
              )
            else ...[
              Text(
                l10n.clientUpdatePackageHint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: UtenSpacing.s8),
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _busy ? null : _choose,
                child: Text(_fileName ?? l10n.clientUpdateChooseFile),
              ),
            ],
            if (_busy) ...[
              const SizedBox(height: UtenSpacing.s16),
              Text(l10n.clientUpdatePublishing),
              LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            ],
            if (_result != null)
              Padding(
                padding: const EdgeInsets.only(top: UtenSpacing.s16),
                child: Text(
                  _result!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
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
                        '${release.platform} ${release.architecture}  ${release.version}+${release.buildNumber}',
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
            isLoading: _busy,
            onPressed: _publish,
            icon: Icons.publish_rounded,
            child: Text(l10n.clientUpdatePublish),
          ),
        ],
      ),
    );
  }
}
