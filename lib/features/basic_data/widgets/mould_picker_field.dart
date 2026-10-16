// 模具选择字段（货品编辑表单「生产」组）：点击打开底部搜索滑窗，按编号/名称/位置/
// 备注模糊搜模具主档，点行即选；表单值提交模具 UUID（mouldId），展示为「编号 名称」。
//
// StatefulWidget 持有本地值：MasterEditForm 的 customBuilder 每次 onChanged 后都会用
// 同一份静态 ctx.initialValue 重新构建（详见 PackagingPickerField 同类注释），必须靠
// 自身 state 记账，否则选中后一 setState 就被冲回旧值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_paged_picker_list.dart';
import '../models/mould_node.dart';
import '../repositories/mould_repository.dart';

class MouldPickerField extends StatefulWidget {
  const MouldPickerField({
    super.key,
    required this.initialValue,
    required this.initialDisplay,
    required this.onChanged,
  });

  /// 表单提交值（模具 UUID 或空串/null）。
  final String? initialValue;

  /// 只读展示文案（如「19-05-43-A Z9 146 45A插面」；详情 mouldCode/mouldName 拼接）。
  final String? initialDisplay;

  /// 回写提交值（mouldId 字段，UUID 字符串或 null）。
  final void Function(dynamic value) onChanged;

  @override
  State<MouldPickerField> createState() => _MouldPickerFieldState();
}

class _MouldPickerFieldState extends State<MouldPickerField> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialDisplay ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(dynamic uuid, String display) {
    setState(() => _ctl.text = display);
    widget.onChanged(uuid);
  }

  Future<void> _pick() async {
    final picked = await showModalBottomSheet<MouldListItem>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => const _MouldSearchSheet(),
    );
    if (picked == null || !mounted) return;
    _set(picked.id, _mouldLabel(picked));
  }

  static String _mouldLabel(MouldListItem m) {
    final code = m.code ?? '';
    final name = m.name ?? '';
    if (code.isEmpty) return name;
    if (name.isEmpty) return code;
    return '$code $name';
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = _ctl.text.isNotEmpty;
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: '模具',
        hintText: '点击搜索模具主档',
        suffixIcon: hasValue
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '清除',
                onPressed: () => _set(null, ''),
              )
            : const Icon(Icons.chevron_right_rounded),
      ),
      onTap: _pick,
    );
  }
}

/// 底部模具搜索滑窗：关键词防抖搜索 + 结果列表（点击行返回该模具）。
class _MouldSearchSheet extends ConsumerStatefulWidget {
  const _MouldSearchSheet();

  @override
  ConsumerState<_MouldSearchSheet> createState() => _MouldSearchSheetState();
}

class _MouldSearchSheetState extends ConsumerState<_MouldSearchSheet> {
  final _searchCtl = TextEditingController();
  List<MouldListItem> _results = const [];
  bool _loading = false;
  String? _error;
  String _query = '';
  int _requestVersion = 0;
  int _page = 1;
  int _requestedPage = 1;
  int _totalPages = 1;

  @override
  void initState() {
    super.initState();
    // 进滑窗先给一页默认结果，空关键词也能选。
    _search('');
  }

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  void _onInputChanged(String text) {
    setState(() {
      _requestVersion++;
      _query = text.trim();
      _results = const [];
      _page = 1;
      _requestedPage = 1;
      _totalPages = 1;
      _error = null;
      _loading = true;
    });
  }

  Future<void> _search(String text, {int page = 1}) async {
    final query = text.trim();
    if (!mounted || query != _searchCtl.text.trim()) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _query = query;
      _requestedPage = page;
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(mouldRepositoryProvider)
          .search(query, page: page, size: 50);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _results = result.items;
        _page = result.page;
        _totalPages = result.totalPages < 1 ? 1 : result.totalPages;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _error = '模具搜索失败，请重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        // 键盘弹起时滑窗跟随上移。
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SizedBox(
        height: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('选择模具', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            UtenSearchBar(
              controller: _searchCtl,
              autofocus: true,
              hint: '模具编号 / 名称 / 位置 / 制造商 / 备注',
              onInputChanged: _onInputChanged,
              onChanged: _search,
              onSubmitted: _search,
            ),
            const SizedBox(height: 12),
            Expanded(
              child: UtenPagedPickerList<MouldListItem>(
                key: const Key('mould-picker-results'),
                items: _results,
                idOf: (mould) => mould.id,
                currentPage: _page,
                totalPages: _totalPages,
                paginationScope: _query,
                loading: _loading,
                error: _error,
                onRetry: () => _search(_query, page: _requestedPage),
                emptyMessage: '没有匹配的模具',
                onPageChange: (page) => _search(_query, page: page),
                itemBuilder: (ctx, m) {
                  return ListTile(
                    dense: true,
                    title: Text(
                      m.code ?? '（无编号）',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: (m.name ?? '').isEmpty
                        ? null
                        : Text(
                            m.name!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                    trailing: (m.place ?? '').isEmpty
                        ? null
                        : Text(
                            m.place!,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                    onTap: () => Navigator.pop(ctx, m),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
