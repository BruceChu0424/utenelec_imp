import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_paged_picker_list.dart';
import '../../../core/network/api_exception.dart';
import '../../models/paged_result.dart';
import '../../providers/sensitive_read_boundary_provider.dart';
import '../material_trace_models.dart';
import '../material_trace_repository.dart';

Future<MaterialTraceSubject?> showMaterialTraceSubjectPicker(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  return showUtenAdaptivePanel<MaterialTraceSubject>(
    context: context,
    drawerWidth: 720,
    builder: (_) => UncontrolledProviderScope(
      container: container,
      child: _SubjectPicker(kind: kind),
    ),
  );
}

class _SubjectPicker extends ConsumerStatefulWidget {
  const _SubjectPicker({required this.kind});
  final String kind;

  @override
  ConsumerState<_SubjectPicker> createState() => _SubjectPickerState();
}

class _SubjectPickerState extends ConsumerState<_SubjectPicker> {
  final _controller = TextEditingController();
  PagedResult<MaterialTraceSubject>? _data;
  SensitiveReadBoundary? _loadedBoundary;
  String? _loadedKeyword;
  String _keyword = '';
  String? _error;
  bool _loading = false;
  bool _exact = false;
  int _request = 0;

  bool get _batch => widget.kind == 'batch';

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (old, next) {
      if (old == next) return;
      setState(() {
        _invalidate();
        _error = '账号、服务器或权限已变化，请重新搜索';
      });
    });
  }

  void _invalidate() {
    ++_request;
    _data = null;
    _loadedBoundary = null;
    _loadedKeyword = null;
    _loading = false;
    _error = null;
  }

  void _input(String text) {
    setState(() {
      _keyword = text.trim();
      _invalidate();
    });
  }

  Future<void> _load(int page) async {
    if (_keyword.isEmpty) return;
    final request = ++_request;
    final keyword = _keyword;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final repository = ref.read(materialTraceRepositoryProvider);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await repository.subjects(
        kind: widget.kind,
        keyword: keyword,
        exact: _exact,
        page: page,
      );
      if (!mounted ||
          request != _request ||
          boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      setState(() {
        _data = data;
        _loadedBoundary = boundary;
        _loadedKeyword = keyword;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error is ApiException ? error.message : '查询失败，请重试';
        _loading = false;
      });
    }
  }

  void _select(MaterialTraceSubject item) {
    if (_loadedBoundary != ref.read(sensitiveReadBoundaryProvider) ||
        _loadedKeyword != _keyword ||
        item.id.isEmpty ||
        item.type.isEmpty) {
      return;
    }
    Navigator.of(context).pop(item);
  }

  @override
  void dispose() {
    ++_request;
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ListTile(
        title: Text(_batch ? '选择生产批次' : '选择追溯单据'),
        trailing: IconButton(
          tooltip: '关闭',
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: UtenSearchBar(
          key: const Key('material-trace-subject-search'),
          controller: _controller,
          hint: _batch ? '输入生产批次号或报工单号' : '输入采购、委外、生产或出入库单号',
          debounce: const Duration(milliseconds: 250),
          onInputChanged: _input,
          onChanged: (_) => _load(1),
          onSubmitted: (_) => _load(1),
        ),
      ),
      CheckboxListTile(
        dense: true,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('精确匹配编号'),
        value: _exact,
        onChanged: (value) {
          setState(() {
            _exact = value ?? false;
            _invalidate();
          });
          _load(1);
        },
      ),
      Expanded(
        child: UtenPagedPickerList<MaterialTraceSubject>(
          key: ValueKey(('material-trace-subjects', widget.kind)),
          items: _data?.items ?? const [],
          idOf: (item) => '${item.type}:${item.id}',
          currentPage: _data?.page ?? 1,
          totalPages: _data?.totalPages ?? 1,
          paginationScope: (widget.kind, _keyword, _exact, _loadedBoundary),
          onPageChange: _load,
          loading: _loading,
          error: _error,
          onRetry: () => _load(_data?.page ?? 1),
          emptyMessage: _keyword.isEmpty
              ? (_batch ? '输入生产批次号或报工单号开始搜索' : '输入单号开始搜索')
              : '没有当前权限范围内的匹配记录',
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, item) => ListTile(
            key: ValueKey(('material-trace-subject', item.type, item.id)),
            title: Text(item.code.isEmpty ? item.displayName : item.code),
            subtitle: Text(
              [
                materialTraceSubjectTypeLabel(item.type),
                if (item.label.isNotEmpty && item.label != item.code)
                  item.label,
                if (item.documentDate != null) item.documentDate!,
                if (item.goodsName != null) item.goodsName!,
                if (item.status != null) materialTraceStatusLabel(item.status!),
              ].join(' · '),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _select(item),
          ),
        ),
      ),
    ],
  );
}
