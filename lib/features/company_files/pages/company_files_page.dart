import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_context_menu_policy.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_motion.dart';
import '../../../components/inputs/uten_drop_target.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/attachments/attachment_file_rules.dart';
import '../../../shared/attachments/attachment_preview_dialog.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/company_file.dart';
import '../models/company_file_access_draft.dart';
import '../models/company_file_upload.dart';
import '../repositories/company_file_repository.dart';
import '../widgets/company_file_dialogs.dart';
import '../widgets/company_file_item.dart';

/// The explorer owns only selection, navigation and upload attempts. Every
/// capability in a toolbar or context menu comes from the current server DTO.
class CompanyFilesPage extends ConsumerStatefulWidget {
  const CompanyFilesPage({super.key});
  @override
  ConsumerState<CompanyFilesPage> createState() => _CompanyFilesPageState();
}

class _CompanyFilesPageState extends ConsumerState<CompanyFilesPage>
    with WidgetsBindingObserver {
  CompanyFileListing? _listing;
  CompanyFile? _selected;
  Object? _error;
  bool _loading = true, _busy = false, _trash = false, _details = false;
  String? _parentId;
  String _search = '', _sort = 'name', _direction = 'asc';
  int _page = 0, _request = 0, _epoch = 0;
  CompanyFileView _view = CompanyFileView.icons;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  var _searchFieldKey = GlobalKey(debugLabel: 'companyFilesSearch');
  bool _directoryExpanded = true;
  CompanyFile? _clipboardEntry;
  SensitiveReadBoundary? _clipboardBoundary;
  bool _clipboardCut = false;
  final _searchController = TextEditingController();
  final List<CompanyFileUpload> _queue = [];
  final Map<CompanyFileUpload, String?> _destinations = {};
  bool _queueRunning = false, _stopQueue = false;
  SensitiveReadBoundary? _queueBoundary;

  AppLocalizations get l => AppLocalizations.of(context);
  CompanyFileRepository get repository =>
      ref.read(companyFileRepositoryProvider);
  bool get _blocked => _busy || _queueRunning;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(sensitiveReadBoundaryProvider, (before, after) {
      if (before == after || !mounted) return;
      ++_epoch;
      ++_request;
      _stopQueue = true;
      setState(() {
        _listing = null;
        _selected = null;
        _error = null;
        _parentId = null;
        _page = 0;
        _search = '';
        _trash = false;
        _busy = false;
        _queueRunning = false;
        _queue.clear();
        _destinations.clear();
        _queueBoundary = null;
        _clipboardEntry = null;
        _clipboardBoundary = null;
        _searchController.clear();
        _searchFieldKey = GlobalKey(debugLabel: 'companyFilesSearch');
        _loading = true;
      });
      unawaited(_load());
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    ++_epoch;
    ++_request;
    _stopQueue = true;
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted && !_blocked) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final request = ++_request, epoch = _epoch;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        request == _request &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await repository.list(
        parentId: _parentId,
        search: _search,
        sort: _sort,
        direction: _direction,
        trash: _trash,
        page: _page,
      );
      if (!mounted || !current()) return;
      setState(() {
        _listing = value;
        if (_selected != null) {
          _selected = value.entries
              .where((e) => e.id == _selected!.id)
              .firstOrNull;
        }
      });
    } catch (e) {
      if (!mounted || !current()) return;
      setState(() {
        _error = e;
        if (e is ApiException && {401, 403, 404}.contains(e.httpStatus)) {
          _listing = null;
          _selected = null;
        }
      });
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  void _navigate(String? id, {bool trash = false}) {
    if (_blocked) return;
    setState(() {
      _parentId = id;
      _trash = trash;
      _page = 0;
      _listing = null;
      _selected = null;
      _search = '';
      _searchController.clear();
      _searchFieldKey = GlobalKey(debugLabel: 'companyFilesSearch');
    });
    unawaited(_load());
  }

  Future<void> _command(
    Future<bool> Function(
      AuthenticatedRequestScope scope,
      SensitiveReadBoundary boundary,
    )
    action, {
    bool refresh = true,
    bool feedback = true,
    bool revalidateOnReturn = false,
  }) async {
    if (_blocked) return;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() => _busy = true);
    try {
      final scope = await boundary.api.captureRequestScope(isCurrent: current);
      final changed = await action(scope, boundary);
      if (!mounted || !current()) return;
      if (changed && feedback) context.appSuccess(l.companyFilesChanged);
      if ((changed || revalidateOnReturn) && refresh) await _load();
    } catch (e) {
      if (mounted && current()) {
        context.appError(companyFileError(e, l));
        if (e is ApiException && {401, 403, 404, 409}.contains(e.httpStatus)) {
          await _load();
        }
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _newFolder() => _command((scope, boundary) async {
    final target = _parentId;
    final value = await showDialog<CompanyFileCreateFolderDraft>(
      context: context,
      builder: (_) => CompanyFileScopeBoundary(
        boundary: boundary,
        scope: scope,
        child: CompanyFileCreateFolderDialog(
          repository: repository,
          scope: scope,
          boundary: boundary,
        ),
      ),
    );
    if (value == null) return false;
    await scope.run(
      () => repository.createFolder(
        parentId: target,
        name: value.name,
        description: value.description,
        access: value.access,
      ),
    );
    return true;
  });

  Future<void> _rename(CompanyFile file) => _command((scope, boundary) async {
    final value = await showDialog<({String name, String description})>(
      context: context,
      builder: (_) => CompanyFileScopeBoundary(
        boundary: boundary,
        scope: scope,
        child: CompanyFileNameDialog(entry: file),
      ),
    );
    if (value == null) return false;
    await scope.run(
      () => repository.rename(
        file,
        name: value.name,
        description: value.description,
      ),
    );
    return true;
  });

  Future<void> _delete(CompanyFile file) => _command((scope, boundary) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => CompanyFileScopeBoundary(
        boundary: boundary,
        scope: scope,
        child: UtenAlertDialog(
          title: Text(l.companyFilesDelete),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(file.name, style: Theme.of(ctx).textTheme.titleMedium),
              const SizedBox(height: UtenSpacing.s12),
              Text(l.companyFilesDeleteHint),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.companyFilesCancel),
            ),
            UtenButton(
              type: UtenButtonType.danger,
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.companyFilesDelete),
            ),
          ],
        ),
      ),
    );
    if (yes != true) return false;
    await scope.run(() => repository.delete(file));
    return true;
  });

  Future<void> _restore(CompanyFile file) => _command((scope, _) async {
    await scope.run(() => repository.restore(file));
    return true;
  });

  Future<void> _move(CompanyFile file) => _command((scope, boundary) async {
    final destination = await showDialog<CompanyFileDestination>(
      context: context,
      builder: (_) => CompanyFileScopeBoundary(
        boundary: boundary,
        scope: scope,
        child: CompanyFileMoveDialog(
          source: file,
          repository: repository,
          scope: scope,
        ),
      ),
    );
    if (destination == null) return false;
    await scope.run(() => repository.move(file, destination.id));
    return true;
  });

  Future<void> _access(CompanyFile file) => _command(
    (scope, boundary) async =>
        await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => CompanyFileAccessDialog(
            entry: file,
            repository: repository,
            scope: scope,
            boundary: boundary,
          ),
        ) ==
        true,
  );

  Future<void> _password(CompanyFile file, {bool unlock = false}) =>
      _command((scope, boundary) async {
        final choice = await showDialog<CompanyFilePasswordChoice>(
          context: context,
          builder: (_) => CompanyFileScopeBoundary(
            boundary: boundary,
            scope: scope,
            child: CompanyFilePasswordDialog(entry: file, unlock: unlock),
          ),
        );
        if (choice == null) return false;
        if (unlock) {
          await scope.run(() => repository.unlock(file.id, choice.password!));
        } else {
          await scope.run(() => repository.setPassword(file, choice.password));
        }
        return true;
      });

  Future<void> _lock(CompanyFile file) => _command((scope, _) async {
    await scope.run(() => repository.lock(file.id));
    return true;
  });

  Future<void> _open(CompanyFile file) async {
    if (_blocked) return;
    final epoch = _epoch;
    if (file.locked) {
      await _password(file, unlock: true);
      if (!mounted || _blocked || epoch != _epoch) return;
      final current = _listing?.entries
          .where((e) => e.id == file.id)
          .firstOrNull;
      if (current?.locked != false) return;
      file = current!;
    }
    if (file.isFolder) {
      _navigate(file.id, trash: _trash);
      return;
    }
    if (file.pending) {
      if (file.allows('upload')) {
        await _pickFiles(resume: file);
      } else {
        _showDetails(file);
      }
      return;
    }
    if (file.allows('download')) await _readFile(file, preview: true);
  }

  Future<void> _readFile(CompanyFile file, {bool preview = false}) => _command(
    (scope, boundary) async {
      final service = ref.read(attachmentServiceProvider);
      final rows = await scope.run(
        () => service.list(ownerType: 'COMPANY_FILE', ownerId: file.id),
      );
      scope.checkCurrent();
      final attachment = rows
          .where((a) => a.id == file.attachmentId && !a.deleted)
          .firstOrNull;
      if (attachment == null) {
        throw ApiException(
          'NOT_FOUND',
          l.companyFilesLoadFailed,
          httpStatus: 404,
        );
      }
      final canPreview =
          preview && canPreviewAttachment(file.name, file.contentType);
      final converted =
          canPreview &&
          attachmentNeedsServerConversion(file.name, file.contentType);
      Uint8List bytes;
      try {
        bytes = await scope.run(
          () => converted
              ? service.previewBytes(attachment)
              : service.downloadBytes(attachment),
        );
      } catch (e) {
        if (!converted ||
            !mounted ||
            !scope.isCurrent ||
            isSessionBoundaryError(e)) {
          rethrow;
        }
        final download = await showDialog<bool>(
          context: context,
          builder: (ctx) => CompanyFileScopeBoundary(
            boundary: boundary,
            scope: scope,
            child: UtenAlertDialog(
              title: Text(l.companyFilesPreviewUnavailable),
              content: Text(companyFileError(e, l)),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(l.companyFilesCancel),
                ),
                UtenButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(l.companyFilesDownload),
                ),
              ],
            ),
          ),
        );
        if (download != true) return false;
        final original = await scope.run(
          () => service.downloadBytes(attachment),
        );
        await saveBytes(
          original,
          file.name,
          stillCurrent: () => scope.isCurrent,
        );
        return false;
      }
      scope.checkCurrent();
      if (!mounted) return false;
      if (canPreview) {
        await showDialog<void>(
          context: context,
          builder: (_) => CompanyFileScopeBoundary(
            boundary: boundary,
            scope: scope,
            child: _CompanyFilePreview(
              bytes: bytes,
              name: file.name,
              contentType: converted ? 'application/pdf' : file.contentType,
              onDownload: () async {
                scope.checkCurrent();
                final original = converted
                    ? await scope.run(() => service.downloadBytes(attachment))
                    : bytes;
                scope.checkCurrent();
                await saveBytes(
                  original,
                  file.name,
                  stillCurrent: () => scope.isCurrent,
                );
              },
            ),
          ),
        );
      } else {
        final path = await saveBytes(
          bytes,
          file.name,
          stillCurrent: () => scope.isCurrent,
        );
        if (mounted && scope.isCurrent) {
          context.appSuccess('${l.companyFilesSavedTo}: $path');
        }
      }
      return false;
    },
    revalidateOnReturn: true,
    feedback: false,
  );

  Future<void> _dropOn(CompanyFile source, CompanyFile target) async {
    if (_blocked || source.id == target.id || !source.allows('move')) return;
    if (_canReorder) {
      final ordered = _listing!.entries.toList();
      final targetIndex = ordered.indexWhere((e) => e.id == target.id);
      ordered.removeWhere((e) => e.id == source.id);
      ordered.insert(targetIndex.clamp(0, ordered.length), source);
      await _reorder(ordered);
    } else if (target.isFolder) {
      await _command((scope, _) async {
        await scope.run(() => repository.move(source, target.id));
        return true;
      });
    }
  }

  bool get _canReorder =>
      !_trash &&
      _sort == 'manual' &&
      _direction == 'asc' &&
      _search.isEmpty &&
      _listing != null &&
      _listing!.total == _listing!.entries.length &&
      _listing!.canReorder &&
      _listing!.entries.every((e) => e.allows('move'));

  Future<void> _reorder(List<CompanyFile> ordered) =>
      _command((scope, _) async {
        await scope.run(() => repository.reorder(_parentId, ordered));
        return true;
      }, feedback: false);

  Future<void> _shift(CompanyFile file, int amount) async {
    if (!_canReorder) return;
    final rows = _listing!.entries.toList();
    final i = rows.indexWhere((e) => e.id == file.id),
        next = rows.indexWhere((e) => e.id == file.id) + amount;
    if (i < 0 || next < 0 || next >= rows.length) return;
    rows.removeAt(i);
    rows.insert(next, file);
    await _reorder(rows);
  }

  List<UtenContextMenuEntry> _menuEntries(CompanyFile e) => [
    if ((!e.deleted || e.isFolder) && e.allows('view'))
      UtenMenuItem(
        label: l.companyFilesOpen,
        icon: e.isFolder ? Icons.folder_open_outlined : Icons.open_in_new,
        enabled: !_blocked,
        onTap: () => _open(e),
      ),
    if (!e.isFolder && !e.pending && e.allows('download'))
      UtenMenuItem(
        label: l.companyFilesDownload,
        icon: Icons.download_outlined,
        enabled: !_blocked,
        onTap: () => _readFile(e),
      ),
    if (!e.deleted && !e.pending && !e.isFolder && e.allows('download'))
      UtenMenuItem(
        label: l.companyFilesCopy,
        icon: Icons.copy_outlined,
        enabled: !_blocked,
        onTap: () => _putClipboard(e, cut: false),
      ),
    if (!e.deleted && e.allows('move'))
      UtenMenuItem(
        label: l.companyFilesCut,
        icon: Icons.content_cut,
        enabled: !_blocked,
        onTap: () => _putClipboard(e, cut: true),
      ),
    UtenMenuItem(
      label: l.companyFilesDetails,
      icon: Icons.info_outline,
      onTap: () => _showDetails(e),
    ),
    if (!e.deleted && e.allows('edit'))
      UtenMenuItem(
        label: l.companyFilesRename,
        icon: Icons.drive_file_rename_outline,
        enabled: !_blocked,
        onTap: () => _rename(e),
      ),
    if (!e.deleted && e.allows('move'))
      UtenMenuItem(
        label: l.companyFilesMove,
        icon: Icons.drive_file_move_outline,
        enabled: !_blocked,
        onTap: () => _move(e),
      ),
    if (_canReorder && e.allows('move')) ...[
      UtenMenuItem(
        label: l.companyFilesUp,
        icon: Icons.arrow_upward,
        enabled: !_blocked,
        onTap: () => _shift(e, -1),
      ),
      UtenMenuItem(
        label: l.companyFilesDown,
        icon: Icons.arrow_downward,
        enabled: !_blocked,
        onTap: () => _shift(e, 1),
      ),
    ],
    if (!e.deleted && e.allows('manage_permissions')) ...[
      const UtenMenuDivider(),
      UtenMenuItem(
        label: l.companyFilesAccess,
        icon: Icons.admin_panel_settings_outlined,
        enabled: !_blocked,
        onTap: () => _access(e),
      ),
      UtenMenuItem(
        label: l.companyFilesPassword,
        icon: Icons.password,
        enabled: !_blocked,
        onTap: () => _password(e),
      ),
    ],
    if (e.passwordProtected)
      UtenMenuItem(
        label: e.locked ? l.companyFilesUnlock : l.companyFilesLock,
        icon: e.locked ? Icons.lock_open_outlined : Icons.lock_outline,
        enabled: !_blocked,
        onTap: () => e.locked ? _password(e, unlock: true) : _lock(e),
      ),
    if (e.deleted && e.allows('restore'))
      UtenMenuItem(
        label: l.companyFilesRestore,
        icon: Icons.restore,
        enabled: !_blocked,
        onTap: () => _restore(e),
      ),
    if (!e.deleted && e.allows('delete')) ...[
      const UtenMenuDivider(),
      UtenMenuItem(
        label: l.companyFilesDelete,
        icon: Icons.delete_outline,
        destructive: true,
        enabled: !_blocked,
        onTap: () => _delete(e),
      ),
    ],
  ];

  Future<void> _showMenu(CompanyFile e, Offset offset) => showUtenContextMenu(
    context,
    globalPosition: offset,
    entries: _guardMenu(_menuEntries(e)),
  );

  List<UtenContextMenuEntry> _guardMenu(List<UtenContextMenuEntry> entries) {
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    return entries
        .map(
          (entry) => entry is UtenMenuItem
              ? UtenMenuItem(
                  label: entry.label,
                  icon: entry.icon,
                  enabled: entry.enabled,
                  destructive: entry.destructive,
                  preserveSelectionAfterAction:
                      entry.preserveSelectionAfterAction,
                  onTap: () async {
                    if (!mounted ||
                        epoch != _epoch ||
                        boundary != ref.read(sensitiveReadBoundaryProvider)) {
                      return;
                    }
                    await entry.onTap();
                  },
                )
              : entry,
        )
        .toList(growable: false);
  }

  void _putClipboard(CompanyFile file, {required bool cut}) {
    if (_blocked ||
        file.deleted ||
        (cut
            ? !file.allows('move')
            : file.isFolder || file.pending || !file.allows('download'))) {
      return;
    }
    setState(() {
      _clipboardEntry = file;
      _clipboardBoundary = ref.read(sensitiveReadBoundaryProvider);
      _clipboardCut = cut;
    });
    context.appInfo(cut ? l.companyFilesCutReady : l.companyFilesCopied);
  }

  bool get _canPaste {
    final source = _clipboardEntry;
    return !_blocked &&
        !_trash &&
        source != null &&
        _clipboardBoundary == ref.read(sensitiveReadBoundaryProvider) &&
        _listing?.folder?.locked != true &&
        _listing?.allows(
              _clipboardCut && source.isFolder ? 'create' : 'upload',
            ) ==
            true &&
        (!_clipboardCut || _listing?.allows('move') == true);
  }

  String _copyName(String name) {
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 ? name.substring(dot) : '';
    final stem = dot > 0 ? name.substring(0, dot) : name;
    final existing = _listing!.entries.map((e) => e.name.toLowerCase()).toSet();
    for (var index = 1; ; index++) {
      final suffix =
          ' - ${l.companyFilesCopySuffix}${index == 1 ? '' : ' ($index)'}$extension';
      final prefix = StringBuffer();
      for (final rune in stem.runes) {
        final next = String.fromCharCode(rune);
        if (prefix.length + next.length + suffix.length > 180) break;
        prefix.write(next);
      }
      final candidate = '$prefix$suffix';
      if (!existing.contains(candidate.toLowerCase())) return candidate;
    }
  }

  Future<void> _paste() async {
    if (!_canPaste) return;
    final copied = _clipboardEntry!, target = _parentId;
    final epoch = _epoch;
    final cut = _clipboardCut;
    final clipboardBoundary = _clipboardBoundary!;
    CompanyFileUpload? prepared;
    await _command((scope, boundary) async {
      if (boundary != clipboardBoundary) return false;
      CompanyFile source;
      try {
        source = await scope.run(() => repository.get(copied.id));
      } catch (e) {
        if (e is ApiException &&
            {401, 403, 404}.contains(e.httpStatus) &&
            scope.isCurrent) {
          setState(() {
            _clipboardEntry = null;
            _clipboardBoundary = null;
          });
        }
        rethrow;
      }
      if (source.deleted || source.pending || !source.allows('view')) {
        throw ApiException(
          'NOT_FOUND',
          l.companyFilesClipboardUnavailable,
          httpStatus: 404,
        );
      }
      if (source.locked) {
        if (!mounted) return false;
        final choice = await showDialog<CompanyFilePasswordChoice>(
          context: context,
          builder: (_) => CompanyFileScopeBoundary(
            boundary: boundary,
            scope: scope,
            child: CompanyFilePasswordDialog(entry: source, unlock: true),
          ),
        );
        if (choice?.password == null) return false;
        await scope.run(() => repository.unlock(source.id, choice!.password!));
        source = await scope.run(() => repository.get(source.id));
      }
      if (!source.allows(cut ? 'move' : 'download') ||
          source.locked ||
          source.deleted ||
          source.pending) {
        throw ApiException(
          'FORBIDDEN',
          l.companyFilesClipboardUnavailable,
          httpStatus: 403,
        );
      }
      if (cut) {
        if (source.parentId == target) {
          if (mounted) context.appInfo(l.companyFilesSameFolder);
          return false;
        }
        await scope.run(() => repository.move(source, target));
        if (scope.isCurrent) {
          setState(() {
            _clipboardEntry = null;
            _clipboardBoundary = null;
          });
        }
        return true;
      }
      if (source.isFolder || source.sizeBytes > AttachmentLimits.maxFileBytes) {
        throw ApiException(
          'VALIDATION',
          l.companyFilesTooLarge,
          httpStatus: 400,
        );
      }
      if (!mounted) return false;
      final named = await showDialog<({String name, String description})>(
        context: context,
        builder: (_) => CompanyFileScopeBoundary(
          boundary: boundary,
          scope: scope,
          child: CompanyFileNameDialog(
            entry: source,
            initialName: _copyName(source.name),
            copy: true,
          ),
        ),
      );
      scope.checkCurrent();
      if (named == null || !mounted) return false;
      final access = await showDialog<CompanyFileInitialAccessDraft>(
        context: context,
        builder: (_) => CompanyFileUploadAccessDialog(
          repository: repository,
          scope: scope,
          boundary: boundary,
          selectedNames: [named.name],
        ),
      );
      scope.checkCurrent();
      if (access == null) return false;
      // No source bytes are cached by Copy. Each paste rechecks the server and
      // uploads a new physical owner through the normal attachment protocol.
      final attachments = ref.read(attachmentServiceProvider);
      final rows = await scope.run(
        () => attachments.list(ownerType: 'COMPANY_FILE', ownerId: source.id),
      );
      final attachment = rows
          .where((a) => a.id == source.attachmentId && !a.deleted)
          .firstOrNull;
      if (attachment == null) {
        throw ApiException(
          'NOT_FOUND',
          l.companyFilesClipboardUnavailable,
          httpStatus: 404,
        );
      }
      final bytes = await scope.run(
        () => attachments.downloadBytes(attachment),
      );
      scope.checkCurrent();
      final held = _queue.fold<int>(0, (sum, f) => sum + f.bytes.length);
      if (bytes.isEmpty ||
          bytes.length > AttachmentLimits.maxFileBytes ||
          held + bytes.length > kPendingAttachmentMaxTotalBytes) {
        throw ApiException(
          'VALIDATION',
          l.companyFilesBatchTooLarge,
          httpStatus: 400,
        );
      }
      prepared = CompanyFileUpload(
        name: named.name,
        bytes: bytes,
        contentType:
            source.contentType ??
            guessAttachmentContentType(named.name) ??
            'application/octet-stream',
        initialAccess: access,
      );
      return false;
    }, feedback: false);
    if (prepared == null ||
        !mounted ||
        epoch != _epoch ||
        clipboardBoundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    _queueBoundary = clipboardBoundary;
    setState(() {
      _queue.add(prepared!);
      _destinations[prepared!] = target;
    });
    await _runQueue([prepared!]);
  }

  void _showDetails(CompanyFile e) {
    final boundary = ref.read(sensitiveReadBoundaryProvider), epoch = _epoch;
    setState(() {
      _selected = e;
      _details = true;
    });
    if (MediaQuery.sizeOf(context).width < 1220) {
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => CompanyFileScopeBoundary(
          boundary: boundary,
          isCurrent: () => mounted && epoch == _epoch,
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * .78,
            child: _detailPanel(e, close: () => Navigator.pop(context)),
          ),
        ),
      );
    }
  }

  Future<void> _pickFiles({CompanyFile? resume}) async {
    if (_blocked) return;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() => _busy = true);
    try {
      final scope = await boundary.api.captureRequestScope(isCurrent: current);
      final picked = await FilePicker.platform.pickFiles(
        allowMultiple: resume == null,
        withReadStream: true,
      );
      scope.checkCurrent();
      if (picked == null || picked.files.isEmpty) return;
      if (current()) setState(() => _busy = false);
      await _uploadFiles(picked.files, resume: resume);
    } catch (e) {
      if (mounted && current()) context.appError(companyFileError(e, l));
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _uploadFiles(
    List<PlatformFile> files, {
    CompanyFile? resume,
  }) async {
    if (_blocked || _trash || _listing?.allows('upload') != true) return;
    final target = resume == null ? _parentId : resume.parentId;
    final held = _queue.fold<int>(0, (sum, f) => sum + f.bytes.length);
    if (files.fold<int>(held, (sum, f) => sum + f.size) >
        kPendingAttachmentMaxTotalBytes) {
      context.appError(l.companyFilesBatchTooLarge);
      return;
    }
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    final pending = <CompanyFileUpload>[];
    setState(() => _busy = true);
    try {
      final scope = await boundary.api.captureRequestScope(isCurrent: current);
      for (final file in files) {
        scope.checkCurrent();
        if (!mounted) return;
        final type = guessAttachmentContentType(file.name);
        String? problem;
        if (type == null) {
          problem = l.companyFilesUnsupported;
        } else if (file.size > AttachmentLimits.maxFileBytes) {
          problem = l.companyFilesTooLarge;
        } else if (file.bytes == null && file.readStream == null) {
          problem = l.companyFilesUnreadable;
        }
        if (problem != null) {
          context.appError('${file.name}: $problem');
          continue;
        }
        if (resume != null && file.name != resume.name) {
          context.appError('${resume.name}: ${l.companyFilesResumeName}');
          continue;
        }
        Uint8List bytes;
        try {
          final remaining =
              kPendingAttachmentMaxTotalBytes -
              held -
              pending.fold<int>(0, (sum, f) => sum + f.bytes.length);
          final limit = remaining < AttachmentLimits.maxFileBytes
              ? remaining
              : AttachmentLimits.maxFileBytes;
          bytes =
              file.bytes ??
              await readBoundedFileBytes(
                file.readStream!,
                maxBytes: limit,
                canContinue: () => scope.isCurrent,
              );
        } on UtenFileReadLimit {
          if (!mounted || !current()) return;
          context.appError('${file.name}: ${l.companyFilesTooLarge}');
          continue;
        } on UtenFileReadCancelled {
          scope.checkCurrent();
          rethrow;
        } catch (_) {
          if (!mounted || !current()) return;
          context.appError('${file.name}: ${l.companyFilesUnreadable}');
          continue;
        }
        scope.checkCurrent();
        if (bytes.isEmpty || bytes.length > AttachmentLimits.maxFileBytes) {
          if (!mounted) return;
          context.appError(
            '${file.name}: ${bytes.isEmpty ? l.companyFilesUnreadable : l.companyFilesTooLarge}',
          );
          continue;
        }
        if (held +
                pending.fold<int>(0, (sum, f) => sum + f.bytes.length) +
                bytes.length >
            kPendingAttachmentMaxTotalBytes) {
          if (!mounted) return;
          context.appError(l.companyFilesBatchTooLarge);
          break;
        }
        pending.add(
          CompanyFileUpload(
            name: file.name,
            bytes: bytes,
            contentType: type!,
            entry: resume,
          ),
        );
      }
      if (pending.isEmpty || !current() || !mounted) return;
      if (resume == null) {
        final access = await showDialog<CompanyFileInitialAccessDraft>(
          context: context,
          builder: (_) => CompanyFileUploadAccessDialog(
            repository: repository,
            scope: scope,
            boundary: boundary,
            selectedNames: pending.map((f) => f.name).toList(growable: false),
          ),
        );
        scope.checkCurrent();
        if (access == null || !current()) return;
        for (final file in pending) {
          file.initialAccess = access;
        }
      }
      _queueBoundary = boundary;
      setState(() {
        _busy = false;
        _queue.addAll(pending);
        for (final p in pending) {
          _destinations[p] = target;
        }
      });
      await _runQueue(pending);
    } catch (e) {
      if (mounted && current()) context.appError(companyFileError(e, l));
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _runQueue(List<CompanyFileUpload> attempts) async {
    if (_blocked || _queueBoundary != ref.read(sensitiveReadBoundaryProvider)) {
      return;
    }
    final epoch = _epoch, boundary = _queueBoundary!;
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    setState(() {
      _queueRunning = true;
      _stopQueue = false;
    });
    try {
      final scope = await boundary.api.captureRequestScope(isCurrent: current);
      await sendCompanyFileUploadQueue(
        attempts: attempts,
        repository: repository,
        attachments: ref.read(attachmentServiceProvider),
        scope: scope,
        parentIdOf: (file) => _destinations[file],
        shouldStop: () => _stopQueue || !current(),
        onChanged: () {
          if (current()) setState(() {});
        },
      );
    } catch (e) {
      if (mounted && current()) context.appError(companyFileError(e, l));
    } finally {
      if (current()) {
        setState(() {
          _queueRunning = false;
          for (final f in attempts) {
            if (f.state == CompanyFileUploadState.waiting) {
              f.state = CompanyFileUploadState.stopped;
            }
          }
        });
        await _load();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.onPageResume('/company-files', _load);
    final scheme = Theme.of(context).colorScheme;
    final dropKey = (
      ref.watch(sensitiveReadBoundaryProvider),
      _epoch,
      _parentId,
      _trash,
    );
    return Scaffold(
      key: _scaffoldKey,
      appBar: UtenAppBar(
        title: l.companyFilesTitle,
        showBackButton: true,
        actions: [
          UtenRefreshButton(
            key: const ValueKey('company-files-refresh'),
            busy: _loading,
            enabled: !_blocked,
            onRefresh: _load,
          ),
        ],
      ),
      drawer: Drawer(child: SafeArea(child: _navigation())),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _floatingActions(),
      bottomNavigationBar: _queue.isEmpty
          ? null
          : SafeArea(top: false, child: _queuePanel()),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = _useSidebar(box.maxWidth);
            final showDetails =
                _details && _selected != null && box.maxWidth >= 1220;
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  key: const ValueKey('company-files-navigation'),
                  width: wide ? (_directoryExpanded ? 180 : 56) : 0,
                  child: wide
                      ? _navigation(
                          collapsed: !_directoryExpanded,
                          sidebar: true,
                        )
                      : null,
                ),
                SizedBox(
                  width: wide ? 1 : 0,
                  child: wide
                      ? VerticalDivider(width: 1, color: scheme.outlineVariant)
                      : null,
                ),
                Expanded(
                  key: const ValueKey('company-files-workspace'),
                  child: UtenDropTarget(
                    operationKey: dropKey,
                    canContinue: () =>
                        mounted &&
                        dropKey ==
                            (
                              ref.read(sensitiveReadBoundaryProvider),
                              _epoch,
                              _parentId,
                              _trash,
                            ),
                    maxFileBytes: AttachmentLimits.maxFileBytes,
                    maxTotalBytes:
                        kPendingAttachmentMaxTotalBytes -
                        _queue.fold<int>(0, (sum, f) => sum + f.bytes.length),
                    onRejected: (name, reason) => context.appError(
                      '$name: ${switch (reason) {
                        'FILE_TOO_LARGE' => l.companyFilesTooLarge,
                        'BATCH_TOO_LARGE' => l.companyFilesBatchTooLarge,
                        'UNREADABLE' => l.companyFilesUnreadable,
                        _ => l.companyFilesUnsupported,
                      }}',
                    ),
                    enabled:
                        !_blocked &&
                        !_trash &&
                        _listing?.allows('upload') == true,
                    hint: l.companyFilesDropHint,
                    onFiles: (files) => unawaited(_uploadFiles(files)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _breadcrumbs(sidebar: wide),
                        if (_busy || _loading && _listing != null)
                          const LinearProgressIndicator(minHeight: 2),
                        if (_error != null && _listing != null)
                          Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s8),
                            child: Wrap(
                              spacing: UtenSpacing.s8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(companyFileError(_error!, l)),
                                TextButton(
                                  onPressed: _load,
                                  child: Text(l.companyFilesRetry),
                                ),
                              ],
                            ),
                          ),
                        Expanded(
                          child: Listener(
                            key: const ValueKey('company-files-canvas'),
                            behavior: HitTestBehavior.opaque,
                            onPointerDown: (event) {
                              if (event.buttons & kSecondaryButton != 0 &&
                                  claimUtenContextMenuPointer(event)) {
                                unawaited(_showBackgroundMenu(event.position));
                              }
                            },
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _selected = null),
                              child: _content(),
                            ),
                          ),
                        ),
                        if (_listing != null) _footer(),
                      ],
                    ),
                  ),
                ),
                if (showDetails) ...[
                  VerticalDivider(width: 1, color: scheme.outlineVariant),
                  SizedBox(
                    width: 300,
                    child: _detailPanel(
                      _selected!,
                      close: () => setState(() => _details = false),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget? _floatingActions() {
    if (_trash || _listing == null) return null;
    final actions = <Widget>[
      if (_listing!.allows('upload'))
        UtenButton(
          key: const ValueKey('company-files-upload'),
          size: UtenButtonSize.large,
          type: UtenButtonType.secondary,
          icon: Icons.upload_file_outlined,
          onPressed: _blocked ? null : _pickFiles,
          child: Text(l.companyFilesUpload),
        ),
      if (_listing!.allows('create'))
        UtenButton(
          key: const ValueKey('company-files-create'),
          size: UtenButtonSize.large,
          icon: Icons.create_new_folder_outlined,
          onPressed: _blocked ? null : _newFolder,
          child: Text(l.companyFilesNewFolder),
        ),
    ];
    return actions.isEmpty ? null : UtenFloatingActionGroup(children: actions);
  }

  Widget _searchField() {
    final searchKey = _searchFieldKey;
    return KeyedSubtree(
      key: const ValueKey('company-files-search'),
      child: UtenSearchBar(
        key: searchKey,
        controller: _searchController,
        hint: l.companyFilesSearch,
        onInputChanged: (_) {
          if (!mounted || searchKey != _searchFieldKey) return;
          ++_request;
        },
        onChanged: (value) {
          if (!mounted || searchKey != _searchFieldKey) return;
          setState(() {
            _search = value;
            _page = 0;
            _listing = null;
            _selected = null;
          });
          unawaited(_load());
        },
      ),
    );
  }

  List<UtenContextMenuEntry> _backgroundEntries() {
    final selected = _selected;
    return [
      if (!_trash && _listing?.allows('create') == true)
        UtenMenuItem(
          label: l.companyFilesNewFolder,
          icon: Icons.create_new_folder_outlined,
          enabled: !_blocked,
          onTap: _newFolder,
        ),
      if (!_trash && _listing?.allows('upload') == true)
        UtenMenuItem(
          label: l.companyFilesUpload,
          icon: Icons.upload_file_outlined,
          enabled: !_blocked,
          onTap: _pickFiles,
        ),
      const UtenMenuDivider(),
      UtenMenuItem(
        label: l.companyFilesCopy,
        icon: Icons.copy_outlined,
        enabled:
            !_blocked &&
            selected != null &&
            !selected.isFolder &&
            !selected.pending &&
            !selected.deleted &&
            selected.allows('download'),
        onTap: () => _putClipboard(selected!, cut: false),
      ),
      UtenMenuItem(
        label: l.companyFilesCut,
        icon: Icons.content_cut_outlined,
        enabled:
            !_blocked &&
            selected != null &&
            !selected.deleted &&
            selected.allows('move'),
        onTap: () => _putClipboard(selected!, cut: true),
      ),
      UtenMenuItem(
        label: l.companyFilesPaste,
        icon: Icons.content_paste_outlined,
        enabled: _canPaste,
        onTap: _paste,
      ),
      if (_clipboardEntry != null)
        UtenMenuItem(
          label: l.companyFilesClearClipboard,
          icon: Icons.clear,
          onTap: () => setState(() {
            _clipboardEntry = null;
            _clipboardBoundary = null;
          }),
        ),
      const UtenMenuDivider(),
      if (selected != null) ...[
        UtenMenuItem(
          label: l.companyFilesDetails,
          icon: Icons.info_outline,
          onTap: () => _showDetails(selected),
        ),
      ],
      UtenMenuItem(
        label: l.companyFilesRefresh,
        icon: Icons.refresh,
        enabled: !_blocked && !_loading,
        onTap: _load,
      ),
    ];
  }

  Future<void> _showBackgroundMenu(Offset offset) async {
    await showUtenContextMenu(
      context,
      globalPosition: offset,
      entries: _guardMenu(_backgroundEntries()),
    );
  }

  bool _useSidebar(double width) =>
      width >= 1000 && MediaQuery.textScalerOf(context).scale(1) < 1.5;

  Widget _navigation({bool collapsed = false, bool sidebar = false}) => Padding(
    padding: EdgeInsets.all(collapsed ? UtenSpacing.s8 : UtenSpacing.s12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _navItem(
          l.companyFilesLibrary,
          Icons.folder_copy_outlined,
          !_trash,
          () => _navigate(null),
          collapsed: collapsed,
        ),
        const SizedBox(height: UtenSpacing.s8),
        _navItem(
          l.companyFilesTrash,
          Icons.delete_outline,
          _trash,
          () => _navigate(null, trash: true),
          collapsed: collapsed,
        ),
        const Spacer(),
        Flex(
          direction: collapsed ? Axis.vertical : Axis.horizontal,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: Tooltip(
                message: _trash
                    ? l.companyFilesTrashHint
                    : l.companyFilesDragHint,
                child: IconButton(
                  onPressed: () => context.appInfo(
                    _trash ? l.companyFilesTrashHint : l.companyFilesDragHint,
                  ),
                  icon: const Icon(Icons.info_outline),
                ),
              ),
            ),
            if (sidebar) _directoryToggle(sidebar: true),
          ],
        ),
      ],
    ),
  );

  Widget _directoryToggle({required bool sidebar}) => IconButton(
    key: const ValueKey('company-files-toggle-directory'),
    tooltip: sidebar
        ? (_directoryExpanded
              ? l.companyFilesHideDirectory
              : l.companyFilesShowDirectory)
        : l.companyFilesDirectory,
    onPressed: () {
      if (sidebar) {
        setState(() => _directoryExpanded = !_directoryExpanded);
      } else {
        _scaffoldKey.currentState?.openDrawer();
      }
    },
    icon: Icon(sidebar && _directoryExpanded ? Icons.menu_open : Icons.menu),
  );

  Widget _navItem(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap, {
    bool collapsed = false,
  }) => Tooltip(
    message: collapsed ? label : '',
    child: Material(
      color: selected
          ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: .6)
          : Colors.transparent,
      borderRadius: UtenRadius.controlAll,
      child: InkWell(
        borderRadius: UtenRadius.controlAll,
        onTap: _blocked
            ? null
            : () {
                if (_scaffoldKey.currentState?.isDrawerOpen == true) {
                  Navigator.pop(context);
                }
                onTap();
              },
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: collapsed ? 8 : 12,
            vertical: 12,
          ),
          child: Row(
            children: [
              Icon(icon, size: 22),
              if (!collapsed) ...[
                const SizedBox(width: UtenSpacing.s8),
                Expanded(child: Text(label)),
              ],
            ],
          ),
        ),
      ),
    ),
  );

  Widget _breadcrumbs({required bool sidebar}) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: UtenSpacing.s16,
      vertical: UtenSpacing.s8,
    ),
    child: LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth >= 760 &&
            MediaQuery.textScalerOf(context).scale(1) < 1.5;
        final crumbs = SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              _crumb(_trash ? l.companyFilesTrash : l.companyFilesTitle, null),
              if (!_trash || _parentId != null)
                ...?_listing?.breadcrumbs.map((b) => _crumb(b.name, b.id)),
            ],
          ),
        );
        final more = Builder(
          builder: (buttonContext) => IconButton(
            tooltip: l.companyFilesMore,
            onPressed: () {
              final box = buttonContext.findRenderObject()! as RenderBox;
              unawaited(
                _showBackgroundMenu(
                  box.localToGlobal(Offset(0, box.size.height)),
                ),
              );
            },
            icon: const Icon(Icons.more_horiz),
          ),
        );
        if (wide) {
          return Row(
            children: [
              if (!sidebar) _directoryToggle(sidebar: false),
              Expanded(
                child: Row(
                  children: [
                    Flexible(child: crumbs),
                    ..._explorerControls(),
                    more,
                  ],
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              SizedBox(width: 280, child: _searchField()),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                if (!sidebar) _directoryToggle(sidebar: false),
                Expanded(child: crumbs),
                more,
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Row(
              children: [
                ..._explorerControls(),
                const SizedBox(width: UtenSpacing.s4),
                Expanded(child: _searchField()),
              ],
            ),
          ],
        );
      },
    ),
  );

  List<Widget> _explorerControls() => [
    PopupMenuButton<String>(
      tooltip: l.companyFilesSort,
      initialValue: _sort,
      enabled: !_blocked,
      onSelected: (v) {
        setState(() {
          _sort = v;
          _page = 0;
        });
        unawaited(_load());
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'name', child: Text(l.companyFilesName)),
        PopupMenuItem(value: 'updated', child: Text(l.companyFilesUpdated)),
        PopupMenuItem(value: 'size', child: Text(l.companyFilesSize)),
        PopupMenuItem(value: 'manual', child: Text(l.companyFilesManual)),
      ],
      icon: const Icon(Icons.sort),
    ),
    IconButton(
      tooltip: _direction == 'asc'
          ? l.companyFilesAscending
          : l.companyFilesDescending,
      onPressed: _blocked
          ? null
          : () {
              setState(() => _direction = _direction == 'asc' ? 'desc' : 'asc');
              unawaited(_load());
            },
      icon: Icon(
        _direction == 'asc' ? Icons.arrow_upward : Icons.arrow_downward,
      ),
    ),
    PopupMenuButton<CompanyFileView>(
      tooltip: l.companyFilesDetails,
      initialValue: _view,
      onSelected: (v) => setState(() => _view = v),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: CompanyFileView.icons,
          child: Text(l.companyFilesIcons),
        ),
        PopupMenuItem(
          value: CompanyFileView.tiles,
          child: Text(l.companyFilesTiles),
        ),
        PopupMenuItem(
          value: CompanyFileView.details,
          child: Text(l.companyFilesDetails),
        ),
      ],
      icon: Icon(switch (_view) {
        CompanyFileView.icons => Icons.grid_view_rounded,
        CompanyFileView.tiles => Icons.view_agenda_outlined,
        CompanyFileView.details => Icons.view_list_outlined,
      }),
    ),
  ];

  Widget _crumb(String name, String? id) => DragTarget<CompanyFile>(
    onWillAcceptWithDetails: (d) =>
        !_blocked &&
        !_trash &&
        d.data.id != id &&
        d.data.parentId != id &&
        d.data.allows('move'),
    onAcceptWithDetails: (d) => unawaited(
      _command((scope, _) async {
        await scope.run(() => repository.move(d.data, id));
        return true;
      }),
    ),
    builder: (context, candidates, _) => TextButton.icon(
      style: TextButton.styleFrom(
        backgroundColor: candidates.isNotEmpty
            ? Theme.of(context).colorScheme.secondaryContainer
            : null,
      ),
      onPressed: _blocked ? null : () => _navigate(id, trash: _trash),
      icon: Icon(
        id == null
            ? (_trash ? Icons.delete_outline : Icons.folder_open_outlined)
            : Icons.chevron_right,
        size: 18,
      ),
      label: Text(name),
    ),
  );

  Widget _content() {
    if (_listing == null) {
      if (_loading) {
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: UtenSpacing.s16),
                Text(l.companyFilesLoading),
              ],
            ),
          ),
        );
      }
      return UtenEmpty.error(
        message: _error == null
            ? l.companyFilesLoadFailed
            : companyFileError(_error!, l),
        actionLabel: l.companyFilesRetry,
        onAction: _load,
      );
    }
    final listing = _listing!;
    if (listing.folder?.locked == true) {
      return UtenEmpty(
        icon: Icons.lock_outline,
        message: l.companyFilesLocked,
        description: l.companyFilesLockedHint,
        actionLabel: l.companyFilesUnlock,
        onAction: () => _password(listing.folder!, unlock: true),
      );
    }
    if (listing.entries.isEmpty) {
      return UtenEmpty(
        icon: _trash ? Icons.delete_outline : Icons.folder_open_outlined,
        message: _search.isNotEmpty
            ? l.companyFilesNoResults
            : _trash
            ? l.companyFilesTrashEmpty
            : l.companyFilesEmpty,
        description: _search.isNotEmpty
            ? null
            : _trash
            ? l.companyFilesTrashHint
            : l.companyFilesEmptyHint,
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        Widget item(int i) {
          final e = listing.entries[i];
          return CompanyFileItem(
            key: ValueKey(e.id),
            entry: e,
            view: _view,
            selected: _selected?.id == e.id,
            busy: _blocked,
            draggable:
                !_trash &&
                e.allows('move') &&
                (_sort != 'manual' || _canReorder),
            reorderEnabled: _canReorder,
            onSelect: () => setState(() => _selected = e),
            onTap: () {
              setState(() => _selected = e);
              if (box.maxWidth < 600 && !_blocked) {
                if (e.isFolder) {
                  unawaited(_open(e));
                } else {
                  _showDetails(e);
                }
              }
            },
            onOpen: () => unawaited(_open(e)),
            onMenu: (offset) => unawaited(_showMenu(e, offset)),
            onDrop: (source) => unawaited(_dropOn(source, e)),
          );
        }

        final scale = MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.5);
        final extent = _view == CompanyFileView.icons
            ? 178.0 * scale.clamp(1, 1.4)
            : 350.0 * scale.clamp(1, 1.3);
        final height = _view == CompanyFileView.icons
            ? 210.0 + (scale - 1) * 65
            : 106.0 + (scale - 1) * 58;
        final wideDetails = box.maxWidth - 32 > 760 && scale < 1.5;
        return UtenMotion(
          duration: UtenAnim.fast,
          builder: (context, duration) => AnimatedSwitcher(
            duration: duration,
            switchInCurve: UtenAnim.standard,
            child: _view == CompanyFileView.details
                ? Column(
                    key: const ValueKey('details'),
                    children: [
                      if (wideDetails) _detailsHeader(),
                      Expanded(
                        child: ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            16,
                            16,
                            16,
                            UtenFloatingActionGroup.scrollClearance,
                          ),
                          itemCount: listing.entries.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: UtenSpacing.s4),
                          itemBuilder: (_, i) => item(i),
                        ),
                      ),
                    ],
                  )
                : GridView.builder(
                    key: ValueKey(_view),
                    padding: const EdgeInsets.fromLTRB(
                      16,
                      16,
                      16,
                      UtenFloatingActionGroup.scrollClearance,
                    ),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: extent,
                      mainAxisExtent: height,
                      crossAxisSpacing: UtenSpacing.s12,
                      mainAxisSpacing: UtenSpacing.s12,
                    ),
                    itemCount: listing.entries.length,
                    itemBuilder: (_, i) => item(i),
                  ),
          ),
        );
      },
    );
  }

  Widget _detailsHeader() {
    Widget label(String text) => Text(
      text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, UtenSpacing.s8, 28, 0),
      child: Row(
        children: [
          const SizedBox(width: 44),
          Expanded(child: label(l.companyFilesName)),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(
            width: 100,
            child: label('${l.companyFilesType} / ${l.companyFilesSize}'),
          ),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(width: 110, child: label(l.companyFilesUpdatedBy)),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(width: 150, child: label(l.companyFilesUpdated)),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Widget _footer() {
    final listing = _listing!;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s4,
      ),
      child: Wrap(
        spacing: UtenSpacing.s12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            '${listing.total} ${l.companyFilesItems}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_sort == 'manual' && !_trash)
            Text(
              l.companyFilesDragHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          if (listing.total > listing.size) ...[
            IconButton(
              tooltip: l.companyFilesPrevious,
              onPressed: _page == 0 || _blocked
                  ? null
                  : () {
                      _page--;
                      _load();
                    },
              icon: const Icon(Icons.chevron_left),
            ),
            Text('${_page + 1} / ${(listing.total / listing.size).ceil()}'),
            IconButton(
              tooltip: l.companyFilesNext,
              onPressed: (_page + 1) * listing.size >= listing.total || _blocked
                  ? null
                  : () {
                      _page++;
                      _load();
                    },
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ],
      ),
    );
  }

  Widget _detailPanel(CompanyFile e, {required VoidCallback close}) {
    Widget fact(String label, String? value) => value == null || value.isEmpty
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s4),
                SelectableText(value),
              ],
            ),
          );
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          20,
          20,
          20,
          UtenFloatingActionGroup.scrollClearance,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    l.companyFilesDetails,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l.companyFilesClose,
                  onPressed: close,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s20),
            Center(child: CompanyFileIcon(entry: e, size: 74)),
            const SizedBox(height: UtenSpacing.s20),
            SelectableText(
              e.name,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: UtenSpacing.s20),
            fact(l.companyFilesDescription, e.description),
            fact(
              l.companyFilesType,
              e.isFolder
                  ? l.companyFilesFolder
                  : e.contentType ?? l.companyFilesFile,
            ),
            if (!e.isFolder)
              fact(l.companyFilesSize, formatAttachmentSize(e.sizeBytes)),
            if (e.pending)
              fact(l.companyFilesPending, l.companyFilesUnknownHint),
            fact(l.companyFilesCreatedBy, e.createdByName),
            fact(l.companyFilesCreatedAt, DisplayDateTime.format(e.createdAt)),
            fact(l.companyFilesUpdatedBy, e.updatedByName),
            fact(l.companyFilesUpdated, DisplayDateTime.format(e.updatedAt)),
            fact(l.companyFilesDeletedAt, DisplayDateTime.format(e.deletedAt)),
            if (e.passwordProtected)
              fact(l.companyFilesPassword, l.companyFilesProtected),
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                if ((!e.deleted || e.isFolder) && e.allows('view'))
                  UtenButton(
                    onPressed: _blocked
                        ? null
                        : () {
                            close();
                            _open(e);
                          },
                    icon: Icons.open_in_new,
                    child: Text(l.companyFilesOpen),
                  ),
                if (!e.deleted && e.allows('manage_permissions'))
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _blocked
                        ? null
                        : () {
                            close();
                            _access(e);
                          },
                    icon: Icons.admin_panel_settings_outlined,
                    child: Text(l.companyFilesAccess),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _queuePanel() {
    final done = _queue.where((f) => f.complete).length;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .35,
        ),
        child: CustomScrollView(
          primary: false,
          shrinkWrap: true,
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                  vertical: UtenSpacing.s8,
                ),
                child: Wrap(
                  spacing: UtenSpacing.s12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${l.companyFilesQueue}  $done / ${_queue.length}',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    if (_queueRunning)
                      TextButton(
                        onPressed: _stopQueue
                            ? null
                            : () => setState(() => _stopQueue = true),
                        child: Text(l.companyFilesStopQueue),
                      )
                    else
                      TextButton(
                        onPressed: () => setState(() {
                          _queue.clear();
                          _destinations.clear();
                        }),
                        child: Text(l.companyFilesClose),
                      ),
                  ],
                ),
              ),
            ),
            if (_queueRunning)
              const SliverToBoxAdapter(
                child: LinearProgressIndicator(minHeight: 2),
              ),
            SliverList.builder(
              itemCount: _queue.length,
              itemBuilder: (_, i) {
                final f = _queue[i];
                final label = switch (f.state) {
                  CompanyFileUploadState.waiting => l.companyFilesWaiting,
                  CompanyFileUploadState.uploading => l.companyFilesUploading,
                  CompanyFileUploadState.verifying => l.companyFilesVerifying,
                  CompanyFileUploadState.done => l.companyFilesUploaded,
                  CompanyFileUploadState.failed => l.companyFilesUploadFailed,
                  CompanyFileUploadState.unknown => l.companyFilesUnknown,
                  CompanyFileUploadState.stopped => l.companyFilesStopped,
                };
                return ListTile(
                  dense: true,
                  leading: Icon(
                    f.complete
                        ? Icons.check_circle_outline
                        : f.error == null
                        ? Icons.insert_drive_file_outlined
                        : Icons.error_outline,
                    color: f.complete
                        ? Theme.of(context).colorScheme.primary
                        : f.error != null
                        ? Theme.of(context).colorScheme.error
                        : null,
                  ),
                  title: Text(
                    f.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    f.error == null
                        ? label
                        : '$label: ${companyFileError(f.error!, l)}',
                  ),
                  trailing: !_queueRunning && !f.complete
                      ? TextButton(
                          onPressed: () => _runQueue([f]),
                          child: Text(
                            f.state == CompanyFileUploadState.unknown
                                ? l.companyFilesCheckResult
                                : l.companyFilesRetry,
                          ),
                        )
                      : null,
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _CompanyFilePreview extends StatefulWidget {
  const _CompanyFilePreview({
    required this.bytes,
    required this.name,
    required this.contentType,
    required this.onDownload,
  });
  final Uint8List bytes;
  final String name;
  final String? contentType;
  final Future<void> Function() onDownload;
  @override
  State<_CompanyFilePreview> createState() => _CompanyFilePreviewState();
}

class _CompanyFilePreviewState extends State<_CompanyFilePreview> {
  bool _saving = false;
  Future<void> _download() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onDownload();
    } catch (e) {
      if (mounted) {
        context.appError(companyFileError(e, AppLocalizations.of(context)));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: Stack(
      children: [
        AbsorbPointer(
          absorbing: _saving,
          child: AttachmentPreviewDialog(
            bytes: widget.bytes,
            name: widget.name,
            contentType: widget.contentType,
            onDownload: _download,
          ),
        ),
        if (_saving)
          Positioned.fill(
            child: ColoredBox(
              color: Theme.of(context).colorScheme.scrim.withValues(alpha: .2),
              child: const Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    ),
  );
}
