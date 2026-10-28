import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart' show kSecondaryButton;

import '../../../components/feedback/uten_motion.dart';
import '../../../components/feedback/uten_context_menu_policy.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../shared/attachments/attachment_file_rules.dart';
import '../models/company_file.dart';
import 'company_file_detail_row.dart';

enum CompanyFileView { icons, tiles, details }

class CompanyFileItem extends StatelessWidget {
  const CompanyFileItem({
    super.key,
    required this.entry,
    required this.view,
    required this.selected,
    required this.busy,
    required this.onSelect,
    this.onTap,
    required this.onOpen,
    required this.onMenu,
    required this.onDrop,
    this.draggable = false,
    this.reorderEnabled = false,
  });
  final CompanyFile entry;
  final CompanyFileView view;
  final bool selected;
  final bool busy;
  final bool draggable;
  final bool reorderEnabled;
  final VoidCallback onSelect;
  final VoidCallback? onTap;
  final VoidCallback onOpen;
  final ValueChanged<Offset> onMenu;
  final ValueChanged<CompanyFile> onDrop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<CompanyFile>(
      onWillAcceptWithDetails: (d) =>
          !busy &&
          d.data.id != entry.id &&
          (reorderEnabled ||
              (entry.isFolder
                  ? entry.allows('move') &&
                        entry.allows(d.data.isFolder ? 'create' : 'upload')
                  : draggable)),
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final active = candidates.isNotEmpty;
        final child = UtenMotion(
          duration: UtenAnim.fast,
          builder: (context, duration) => AnimatedContainer(
            duration: duration,
            curve: UtenAnim.standard,
            decoration: BoxDecoration(
              color: active
                  ? scheme.secondaryContainer
                  : selected
                  ? scheme.primaryContainer.withValues(alpha: .55)
                  : scheme.surface,
              borderRadius: UtenRadius.controlAll,
              border: Border.all(
                color: active
                    ? scheme.secondary
                    : selected
                    ? scheme.primary.withValues(alpha: .5)
                    : scheme.outlineVariant.withValues(
                        alpha: view == CompanyFileView.details ? .35 : .55,
                      ),
              ),
            ),
            child: CallbackShortcuts(
              bindings: {
                const SingleActivator(LogicalKeyboardKey.enter): onOpen,
                const SingleActivator(LogicalKeyboardKey.space): onSelect,
              },
              child: Focus(
                child: Listener(
                  onPointerDown: (e) {
                    if (e.buttons & kSecondaryButton != 0 &&
                        claimUtenContextMenuPointer(e)) {
                      onSelect();
                      onMenu(e.position);
                    }
                  },
                  child: Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      borderRadius: UtenRadius.controlAll,
                      onTap: onTap ?? onSelect,
                      onDoubleTap: busy ? null : onOpen,
                      child: view == CompanyFileView.icons
                          ? _iconLayout(context)
                          : _rowLayout(context),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        if (!draggable || busy) return child;
        return LongPressDraggable<CompanyFile>(
          data: entry,
          maxSimultaneousDrags: 1,
          feedback: Material(
            elevation: 3,
            color: scheme.surfaceContainerHighest,
            borderRadius: UtenRadius.controlAll,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 250),
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CompanyFileIcon(entry: entry, size: 30),
                    const SizedBox(width: UtenSpacing.s8),
                    Flexible(
                      child: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          childWhenDragging: Opacity(opacity: .35, child: child),
          child: child,
        );
      },
    );
  }

  Widget _menu(BuildContext context) => Builder(
    builder: (buttonContext) => IconButton(
      tooltip: AppLocalizations.of(context).companyFilesDetails,
      onPressed: () {
        onSelect();
        final box = buttonContext.findRenderObject() as RenderBox?;
        onMenu(box?.localToGlobal(Offset(0, box.size.height)) ?? Offset.zero);
      },
      icon: const Icon(Icons.more_horiz_rounded),
    ),
  );

  Widget _iconLayout(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [_menu(context)],
          ),
          Expanded(
            child: Center(child: CompanyFileIcon(entry: entry, size: 54)),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Tooltip(
            message: entry.name,
            child: Text(
              entry.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            _subtitle(context),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rowLayout(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final wideDetails =
            view == CompanyFileView.details &&
            box.maxWidth > 760 &&
            MediaQuery.textScalerOf(context).scale(1) < 1.5;
        if (wideDetails) {
          final l = AppLocalizations.of(context);
          Widget text(String value) => Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          );
          return CompanyFileDetailRow(
            leading: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Center(child: CompanyFileIcon(entry: entry, size: 32)),
            ),
            name: Tooltip(
              message: entry.name,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (entry.description.isNotEmpty) text(entry.description),
                ],
              ),
            ),
            type: text(
              entry.isFolder
                  ? l.companyFilesFolder
                  : attachmentExtension(entry.name).toUpperCase().isEmpty
                  ? l.companyFilesFile
                  : attachmentExtension(entry.name).toUpperCase(),
            ),
            size: Tooltip(
              message:
                  entry.isFolder || entry.pending || entry.attachmentId == null
                  ? ''
                  : '${entry.sizeBytes} B',
              child: text(
                entry.isFolder
                    ? '—'
                    : entry.pending
                    ? l.companyFilesPending
                    : entry.attachmentId == null
                    ? '—'
                    : formatAttachmentSize(entry.sizeBytes),
              ),
            ),
            updatedBy: text(entry.updatedByName ?? ''),
            updated: text(DisplayDateTime.format(entry.updatedAt)),
            trailing: Center(child: _menu(context)),
          );
        }
        return Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s12,
            vertical: UtenSpacing.s12,
          ),
          child: Row(
            children: [
              CompanyFileIcon(
                entry: entry,
                size: view == CompanyFileView.tiles ? 42 : 32,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Tooltip(
                      message: entry.name,
                      child: Text(
                        entry.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      _subtitle(context),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (view == CompanyFileView.details)
                      Text(
                        DisplayDateTime.format(entry.updatedAt),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (view == CompanyFileView.details &&
                        entry.updatedByName != null)
                      Text(
                        entry.updatedByName!,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              _menu(context),
            ],
          ),
        );
      },
    );
  }

  String _subtitle(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (entry.pending) return l.companyFilesPending;
    if (entry.passwordProtected) return l.companyFilesProtected;
    if (entry.isFolder) return l.companyFilesFolder;
    if (entry.attachmentId == null) return '—';
    return formatAttachmentSize(entry.sizeBytes);
  }
}

class CompanyFileIcon extends StatelessWidget {
  const CompanyFileIcon({super.key, required this.entry, this.size = 40});
  final CompanyFile entry;
  final double size;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kind = AttachmentFileKind.of(entry.name, entry.contentType);
    final color = entry.isFolder ? scheme.primary : kind.color;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          entry.isFolder ? Icons.folder_rounded : kind.icon,
          size: size,
          color: color,
        ),
        if (entry.passwordProtected)
          Positioned(
            right: -2,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: scheme.surface,
                borderRadius: UtenRadius.xsAll,
              ),
              child: Padding(
                padding: const EdgeInsets.all(UtenSpacing.s2),
                child: Icon(
                  entry.locked ? Icons.lock_rounded : Icons.lock_open_rounded,
                  color: scheme.onSurfaceVariant,
                  size: size * .32,
                ),
              ),
            ),
          ),
        if (entry.pending)
          Positioned(
            right: -2,
            bottom: 0,
            child: Icon(
              Icons.cloud_upload_outlined,
              color: scheme.onSurfaceVariant,
              size: size * .4,
            ),
          ),
      ],
    );
  }
}
