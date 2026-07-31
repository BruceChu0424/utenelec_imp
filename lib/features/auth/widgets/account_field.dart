// AccountField - 账号输入框 + 历史下拉（点选/删除单个/清除全部）。
//
// 只记账号不记密码（安全铁律）。默认填上次登录账号（AccountHistoryStore.first）；
// 聚焦或点右侧下拉箭头 → 输入框下方浮出历史账号列表：点选填入、每项可删、底部「清除全部」。
// 点外部 / 失焦 / 选定后自动关闭。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/repositories/account_history_store.dart';

class AccountField extends ConsumerStatefulWidget {
  const AccountField({
    super.key,
    required this.controller,
    required this.hint,
    this.textInputAction = TextInputAction.next,
    this.onSubmitted,
    this.validator,
  });

  final TextEditingController controller;
  final String hint;
  final TextInputAction textInputAction;
  final VoidCallback? onSubmitted;
  final String? Function(String?)? validator;

  @override
  ConsumerState<AccountField> createState() => _AccountFieldState();
}

class _AccountFieldState extends ConsumerState<AccountField> {
  final _layerLink = LayerLink();
  final _focus = FocusNode();
  OverlayEntry? _overlay;
  List<String> _history = const [];
  bool _open = false;

  @override
  void initState() {
    super.initState();
    _loadHistory(fillLast: true);
    _focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    _hideDropdown();
    _focus.removeListener(_onFocusChange);
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHistory({bool fillLast = false}) async {
    final h = await ref.read(accountHistoryProvider).getAll();
    if (!mounted) return;
    setState(() {
      _history = h;
      if (fillLast && h.isNotEmpty && widget.controller.text.isEmpty) {
        widget.controller.text = h.first;
      }
    });
  }

  void _onFocusChange() {
    // 仅聚焦时展开。失焦不在这里关闭：点击弹层内的账号项会让 TextField 先失焦，
    // 若立即 _hideDropdown 会把整个弹层（含 InkWell）一并移除，onTap 还没触发就被销毁 → 点账号无反应。
    // 关闭交给：弹层内选中后 onPick/onClear → hide、点外部遮罩 → onClose、下拉箭头切换。
    if (_focus.hasFocus && _history.length > 1) {
      _showDropdown();
    }
  }

  void _toggleDropdown() {
    if (_history.isEmpty) return;
    _open ? _hideDropdown() : _showDropdown();
  }

  void _showDropdown() {
    _hideDropdown();
    if (_history.isEmpty) return;
    final entry = OverlayEntry(
      builder: (_) => _Dropdown(
        layerLink: _layerLink,
        accounts: _history,
        onPick: (a) {
          widget.controller.text = a;
          widget.controller.selection = TextSelection.fromPosition(
            TextPosition(offset: a.length),
          );
          _hideDropdown();
        },
        onDelete: (a) async {
          await ref.read(accountHistoryProvider).remove(a);
          await _loadHistory();
        },
        onClear: () async {
          await ref.read(accountHistoryProvider).clear();
          await _loadHistory();
          _hideDropdown();
        },
        onClose: _hideDropdown,
      ),
    );
    Overlay.of(context).insert(entry);
    _overlay = entry;
    setState(() => _open = true);
  }

  void _hideDropdown() {
    _overlay?.remove();
    _overlay = null;
    if (mounted && _open) setState(() => _open = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CompositedTransformTarget(
      link: _layerLink,
      child: TextFormField(
        controller: widget.controller,
        focusNode: _focus,
        textInputAction: widget.textInputAction,
        autocorrect: false,
        validator: widget.validator,
        autofillHints: const ['username'],
        decoration: InputDecoration(
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.person_outline_rounded),
          suffixIcon: IconButton(
            icon: Icon(_open ? Icons.arrow_drop_up : Icons.arrow_drop_down),
            tooltip: '历史账号',
            onPressed: _toggleDropdown,
          ),
          border: const OutlineInputBorder(),
        ),
        onFieldSubmitted: widget.onSubmitted == null
            ? null
            : (_) {
                _focus.unfocus();
                widget.onSubmitted!();
              },
        style: theme.textTheme.bodyLarge,
      ),
    );
  }
}

/// 下拉浮层：账号列表 + 单项删除 + 清除全部。
class _Dropdown extends StatelessWidget {
  const _Dropdown({
    required this.layerLink,
    required this.accounts,
    required this.onPick,
    required this.onDelete,
    required this.onClear,
    required this.onClose,
  });
  final LayerLink layerLink;
  final List<String> accounts;
  final void Function(String) onPick;
  final void Function(String) onDelete;
  final VoidCallback onClear;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      children: [
        // 点外部关闭
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onClose,
          child: const SizedBox.expand(),
        ),
        Positioned(
          // 用 LayerLink + Follower 手动定位到输入框下方（避免计算坐标）
          child: CompositedTransformFollower(
            link: layerLink,
            targetAnchor: Alignment.bottomLeft,
            offset: const Offset(0, 4),
            child: TapRegion(
              onTapOutside: (_) => onClose(),
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(8),
                color: theme.colorScheme.surface,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 320,
                    maxHeight: 280,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Flexible(
                        child: ListView.builder(
                          shrinkWrap: true,
                          itemCount: accounts.length,
                          itemBuilder: (_, i) {
                            final a = accounts[i];
                            return InkWell(
                              onTap: () => onPick(a),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.person_outline, size: 18),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        a,
                                        style: theme.textTheme.bodyMedium,
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '删除',
                                      iconSize: 18,
                                      visualDensity: VisualDensity.compact,
                                      icon: const Icon(Icons.close, size: 16),
                                      onPressed: () => onDelete(a),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const Divider(height: 1),
                      TextButton.icon(
                        onPressed: onClear,
                        icon: const Icon(Icons.delete_sweep_outlined, size: 18),
                        label: const Text('清除全部'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
