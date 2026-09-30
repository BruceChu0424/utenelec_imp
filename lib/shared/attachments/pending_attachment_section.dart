// 新建单据的「保存前附件」区段：卡片式陈列（方形卡横排，像火车车厢一样一路接龙）。
// 只做选文件 / 列出 / 分类 / 移除，不预览、不下载；真正的上传在单据保存成功后由
// PendingAttachmentController.flush 完成。支持 AI 识别的页面可通过 [actionFor] 在
// 每张卡片底部挂一个动作（如「AI识别」，完成后转「已完成」样式），批量入口经
// [headerExtra] 挂在标题行、配合 [selectionMode]/[selectedItems] 做「先勾选再批量」。
// 权限：调用方表达页面级可写（如新建权限），本组件再叠加 attachment:upload。

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/inputs/uten_drop_target.dart';
import '../../components/layout/uten_section_header.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../auth/permissions.dart';
import 'attachment_category_control.dart';
import 'attachment_file_rules.dart';
import 'attachment_section.dart' show DashedContainer;
import 'pending_attachment_controller.dart';

/// 卡片底部的可选动作规格（如销售的「AI识别」）。宿主页面按文件实时给出：
/// [busy] 时按钮转圈不可点，[done] 时转成功色并显示 [doneLabel]。
class PendingFileActionSpec {
  const PendingFileActionSpec({
    required this.label,
    required this.onTap,
    this.busy = false,
    this.done = false,
    this.doneLabel = '重新识别',
    this.tooltip,
  });

  final String label;
  final String? tooltip;

  /// null = 当前不可用（如整页保存中）。
  final VoidCallback? onTap;
  final bool busy;
  final bool done;
  final String doneLabel;
}

class PendingAttachmentSection extends ConsumerStatefulWidget {
  const PendingAttachmentSection({
    super.key,
    required this.controller,
    required this.canManage,
    this.title = '相关文件',
    this.categories,
    this.emptyHint,
    this.actionFor,
    this.headerExtra,
    this.manageWithoutUploadPerm = false,
    this.selectionMode = false,
    this.selectedItems = const <PendingAttachment>{},
    this.onToggleSelection,
    this.selectableFor,
  });

  final PendingAttachmentController controller;
  final bool canManage;
  final String title;

  /// 分类词表（与已保存单据一致）；为 null 时不提供分类。
  /// 分类是可选标注：选文件时不问，加入之后在卡片上随时可设可清。
  final List<String>? categories;

  /// 空态投放区的首行文案；缺省按分类词表生成。
  final String? emptyHint;

  /// 按暂存文件给出卡片动作（如「AI识别」）；null = 该文件没有动作，
  /// 卡片底部只保留删除。宿主持有状态（识别中/已完成），这里只负责呈现。
  /// 选卡模式(selectionMode)下动作与删除都让位给勾选，不再展示。
  final PendingFileActionSpec? Function(PendingAttachment item)? actionFor;

  /// 标题行「添加文件」旁的额外入口（如「批量识别/确认识别(N)」），由宿主自带状态。
  final Widget? headerExtra;

  /// true = 添加/移除不再叠加 attachment:upload 权限(由宿主页面担保场景合法，
  /// 如销售「识别客户文件」：识别本身不依赖附件权限，没有权限的用户保存时
  /// 附件逐项失败并如实提示)。默认 false = 与既有一致按权限设卡。
  final bool manageWithoutUploadPerm;

  /// 选卡模式：卡片右上角变勾选圈、整卡可点切换勾选(动作/删除/分类暂避让)。
  final bool selectionMode;

  /// 已勾选的文件(按对象本体；宿主持有)。
  final Set<PendingAttachment> selectedItems;

  /// 点卡片切换勾选；null = 本区没有选卡交互。
  final ValueChanged<PendingAttachment>? onToggleSelection;

  /// 哪些文件可勾选(如仅可识别类型)；null = 全部可勾。
  final bool Function(PendingAttachment item)? selectableFor;

  @override
  ConsumerState<PendingAttachmentSection> createState() =>
      _PendingAttachmentSectionState();
}

class _PendingAttachmentSectionState
    extends ConsumerState<PendingAttachmentSection> {
  bool _picking = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canAdd =
        widget.canManage &&
        (widget.manageWithoutUploadPerm ||
            ref
                .watch(currentPermissionsProvider)
                .contains(Perm.attachmentUpload));
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final items = widget.controller.items;
        final busy = _picking || widget.controller.isFlushing;
        // 整段都是拖放接收区（Web/桌面端）：文件拖进来直接加入待保存列表。
        return UtenDropTarget(
          enabled: canAdd && !busy,
          onFiles: _addFiles,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: UtenSectionHeader(
                      title: widget.title,
                      icon: Icons.folder_outlined,
                      trailing: items.isEmpty
                          ? null
                          : _countBadge(theme, items.length),
                    ),
                  ),
                  if (widget.headerExtra != null) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    widget.headerExtra!,
                  ],
                  if (canAdd && !widget.selectionMode) ...[
                    const SizedBox(width: UtenSpacing.s8),
                    FilledButton.tonalIcon(
                      key: const ValueKey('pending-attachment-add'),
                      onPressed: busy ? null : _pick,
                      icon: widget.controller.isFlushing
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.attach_file_rounded, size: 18),
                      label: Text(
                        widget.controller.isFlushing ? '上传中…' : '添加文件',
                      ),
                    ),
                  ],
                ],
              ),
              // 只在真的在传的那几秒出现一行进度；平时不挂静态提示语。
              if (widget.controller.isFlushing)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s4),
                  child: Text(
                    '正在上传到刚保存的单据…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: UtenSpacing.s8),
              if (items.isEmpty)
                canAdd ? _dropzone(theme) : _readonlyEmpty(theme)
              else
                _cardArea(theme, items, canAdd: canAdd, busy: busy),
            ],
          ),
        );
      },
    );
  }

  /// 卡片陈列：文件卡一路横排（排满换行），队尾挂一张虚线「添加」卡。
  Widget _cardArea(
    ThemeData theme,
    List<PendingAttachment> items, {
    required bool canAdd,
    required bool busy,
  }) {
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (int i = 0; i < items.length; i++)
          _FileCard(
            item: items[i],
            categories: widget.categories,
            action: widget.selectionMode
                ? null
                : widget.actionFor?.call(items[i]),
            canRemove: canAdd && !busy && !widget.selectionMode,
            canCategorize: canAdd,
            onRemove: () => widget.controller.removeAt(i),
            onSetCategory: (value) => widget.controller.setCategoryAt(i, value),
            selectionMode: widget.selectionMode,
            selected: widget.selectedItems.contains(items[i]),
            selectable: widget.selectableFor?.call(items[i]) ?? true,
            onToggleSelection: widget.onToggleSelection != null
                ? () => widget.onToggleSelection!(items[i])
                : null,
          ),
        if (canAdd && !busy && !widget.selectionMode) _AddTile(onTap: _pick),
      ],
    );
  }

  Widget _countBadge(ThemeData theme, int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        '$count',
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  /// 空态举例用本页自己的词表（采购单不该写「客户确认」）；这只是举例，不是先分类。
  String get _dropzoneHint {
    final override = widget.emptyHint;
    if (override != null) return override;
    final categories = widget.categories;
    if (categories == null || categories.isEmpty) {
      return '开单时就可以先把相关文件放进来';
    }
    return '开单时就可以先放入${categories.take(3).join('、')}';
  }

  Widget _dropzone(ThemeData theme) {
    return InkWell(
      borderRadius: UtenRadius.mdAll,
      onTap: _picking ? null : _pick,
      child: DashedContainer(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.attach_file_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _dropzoneHint,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      // 上限跟随服务端部署配置 (公共设置下发)，不写死。
                      AppLocalizations.of(context).attachmentUploadFormatsHint(
                        formatAttachmentLimit(AttachmentLimits.maxFileBytes),
                      ),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, size: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _readonlyEmpty(ThemeData theme) {
    return SizedBox(
      width: double.infinity,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.folder_open_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Text(
              '保存后可在单据详情添加文件',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pick() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        withData: true,
        allowMultiple: true,
        allowCompression: false,
      );
      if (!mounted) return;
      final files = result?.files ?? const <PlatformFile>[];
      await _addFiles(files);
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 加入一批文件（文件选择框与拖入共用）：逐个过附件规则，不合规的单独提示。
  Future<void> _addFiles(List<PlatformFile> files) async {
    var accepted = 0;
    for (final f in files) {
      // 加入时不问分类：需要的话在卡片上点一下再设。
      final rejection = widget.controller.add(f);
      if (rejection == null) {
        accepted++;
      } else if (mounted) {
        context.appError(rejection);
      }
    }
    if (mounted && accepted > 0) {
      context.appInfo('已加入 $accepted 个文件');
    }
  }
}

/// 统一卡片尺寸：固定宽高保证横排整齐（文件名单行省略，悬停出全称提示）。
const Size _kCardSize = Size(156, 148);

/// 文件卡：左对齐编辑排版(图标/分类占满顶行、名称单行、元信息一行)，
/// 柔和阴影替代重边框，悬停微升起、失败才换红描边——克制、安静，靠留白和层次出质感。
class _FileCard extends StatefulWidget {
  const _FileCard({
    required this.item,
    required this.canRemove,
    required this.canCategorize,
    required this.onRemove,
    required this.onSetCategory,
    this.categories,
    this.action,
    this.selectionMode = false,
    this.selected = false,
    this.selectable = true,
    this.onToggleSelection,
  });

  final PendingAttachment item;
  final List<String>? categories;
  final PendingFileActionSpec? action;

  final bool canRemove;
  final bool canCategorize;
  final VoidCallback onRemove;
  final ValueChanged<String?> onSetCategory;

  final bool selectionMode;
  final bool selected;
  final bool selectable;
  final VoidCallback? onToggleSelection;

  @override
  State<_FileCard> createState() => _FileCardState();
}

class _FileCardState extends State<_FileCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final item = widget.item;
    final kind = AttachmentFileKind.of(item.name, item.contentType);
    final error = item.lastError;
    final action = widget.action;
    final selected = widget.selected;

    final shadowBase = dark ? Colors.black : const Color(0x0F0F172A);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: AnimatedContainer(
        width: _kCardSize.width,
        height: _kCardSize.height,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected
              ? theme.colorScheme.primary.withValues(alpha: 0.05)
              : dark
              ? theme.colorScheme.surfaceContainerLow
              : theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(UtenRadius.xl),
          border: Border.all(
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: 0.65)
                : error != null
                ? UtenColors.error.withValues(alpha: 0.45)
                : _hovering
                ? theme.colorScheme.outlineVariant.withValues(alpha: 0.9)
                : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
          ),
          boxShadow: [
            BoxShadow(
              color: shadowBase.withValues(alpha: _hovering ? 0.10 : 0.05),
              blurRadius: _hovering ? 12 : 3,
              offset: Offset(0, _hovering ? 4 : 1),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(UtenRadius.xl),
            // 选卡模式整卡可点切换；平时卡面不整卡点击(避免误触盖住按钮)。
            onTap: widget.selectionMode && widget.onToggleSelection != null
                ? (widget.selectable ? widget.onToggleSelection : null)
                : null,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _IconTile(kind: kind),
                      const Spacer(),
                      if (widget.selectionMode)
                        _SelectionMark(
                          selected: selected,
                          enabled: widget.selectable,
                        )
                      else if (widget.canRemove)
                        SizedBox(
                          width: 30,
                          height: 30,
                          child: IconButton(
                            key: ValueKey(
                              'pending-attachment-remove-${item.name}',
                            ),
                            tooltip: '删除',
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 30,
                              height: 30,
                            ),
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 21,
                              color: UtenColors.error,
                            ),
                            onPressed: widget.onRemove,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Tooltip(
                    // 单行省略，全称悬停即出(标题一行，卡片更矮更安静)。
                    message: item.name,
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    error == null
                        ? '${formatAttachmentSize(item.sizeBytes)} · 待保存后上传'
                        : '上传失败：$error',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: error == null
                          ? theme.colorScheme.onSurfaceVariant
                          : UtenColors.error,
                    ),
                  ),
                  const Spacer(),
                  // 底行 = 分类chip(左) + 动作按钮(右)，一行放下不空置。
                  if ((widget.categories != null &&
                          widget.categories!.isNotEmpty) ||
                      action != null)
                    Row(
                      children: [
                        if (widget.categories != null &&
                            widget.categories!.isNotEmpty)
                          Flexible(
                            child: AttachmentCategoryControl(
                              categories: widget.categories!,
                              value: item.category,
                              // 上传那几秒只是暂时不接受点击（enabled=false），入口不消失，卡片不跳动。
                              enabled: widget.canRemove,
                              onChanged: widget.canCategorize
                                  ? widget.onSetCategory
                                  : null,
                              // 紧凑形态：与按钮同排，窄了先省略文字不撑爆。
                              dense: true,
                            ),
                          ),
                        if ((widget.categories != null &&
                                widget.categories!.isNotEmpty) &&
                            action != null)
                          const SizedBox(width: UtenSpacing.s4),
                        // 按钮也允许收缩：极端字号下两项按比例让位、各自省略。
                        if (action != null)
                          Flexible(
                            child: Align(
                              alignment: AlignmentDirectional.centerEnd,
                              child: _ActionButton(
                                key: ValueKey(
                                  'pending-attachment-action-${item.name}',
                                ),
                                spec: action,
                              ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 选卡模式右上角的勾选圈：选中=主色实底对勾，未选=描边空心圈，
/// 不可选=空心圈弱化。
class _SelectionMark extends StatelessWidget {
  const _SelectionMark({required this.selected, required this.enabled});

  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = enabled
        ? theme.colorScheme.primary
        : theme.colorScheme.outlineVariant;
    return AnimatedContainer(
      width: 20,
      height: 20,
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: selected ? color : Colors.transparent,
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.6),
      ),
      child: selected
          ? const Icon(Icons.check_rounded, size: 13, color: Colors.white)
          : null,
    );
  }
}

/// 图标瓦片：文件类型色做极浅底；完成态由底行按钮文字表达，这里不加角标。
class _IconTile extends StatelessWidget {
  const _IconTile({required this.kind});

  final AttachmentFileKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: kind.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(UtenRadius.lg),
      ),
      child: Icon(kind.icon, size: 22, color: kind.color),
    );
  }
}

/// 卡片底部动作按钮：tonal(主色 9% 底)而非细描边——安静但可辨；
/// 进行中=禁用(进度由公共 AI 进度弹窗展示，卡片不转圈——模态弹窗已覆盖屏幕，
/// 卡片动画只会让测试/无障碍永不 settle)；完成=成功色 tonal(仍可点=重新识别)。
class _ActionButton extends StatelessWidget {
  const _ActionButton({super.key, required this.spec});

  final PendingFileActionSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = !spec.busy && spec.onTap != null;
    // 完成态刻意安静: 灰字、无底色、无图标(点它=重新识别)。
    final foreground = spec.done || !enabled
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.primary;
    final button = Material(
      color: spec.done
          ? Colors.transparent
          : theme.colorScheme.primary.withValues(alpha: enabled ? 0.09 : 0.05),
      borderRadius: BorderRadius.circular(UtenRadius.control),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: spec.busy ? null : spec.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Text(
            spec.done ? spec.doneLabel : spec.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: spec.done ? FontWeight.w500 : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
    final tooltip = spec.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// 队尾的虚线「添加」卡：与文件卡同尺寸同圆角，轻轻一层主色晕染，
/// 像火车最后挂一节空车厢。
class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: _kCardSize.width,
      height: _kCardSize.height,
      child: Material(
        color: theme.colorScheme.primary.withValues(alpha: 0.03),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(UtenRadius.xl),
        ),
        child: InkWell(
          onTap: onTap,
          child: DashedContainer(
            borderRadius: UtenRadius.xl,
            child: SizedBox.expand(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.08),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.add_rounded,
                      size: 24,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    '添加文件',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '点击或拖入',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
