// 仓库任务中心页骨架（出库/入库/生产领料三页共用）：AppBar + 大类分段导航
// （带红圆数字徽章 + 页级胶囊搜索框）+ 分段内容区。
//
// 布局对齐品质「待检处置/检查结果」页范式：UtenFilterToolbar 大类在上（每段右侧
// 计数徽章，父分类徽章 = 其子类待办之和，计数取后端全量口径）；各分段内容自带
// 小类行（状态/来源）在下。进页面不预选大类（UtenFilterToolbar「默认不选」
// 范式）——未选择时内容区显示引导空态；小类行只随选中的大类出现（结构上等价
// 于「大类未选时小类锁定」）。返回本页时 [onResume] 触发（重拉分段计数
// provider），刷新按钮通过 refreshTick 传给分段。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_filter_toolbar.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart' show RouteName;
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';

/// 一个任务中心大类分段。
class WarehouseTaskSegmentSpec {
  const WarehouseTaskSegmentSpec({
    required this.value,
    required this.label,
    this.count,
  });

  final String value;
  final String label;

  /// 该分段的待办计数；null = 不显示徽章（无待办语义或加载中）。
  final int? count;
}

class WarehouseTaskCenterScaffold extends ConsumerStatefulWidget {
  const WarehouseTaskCenterScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.searchHint,
    required this.location,
    required this.segments,
    required this.bodyBuilder,
    this.trailingBuilder,
    this.onResume,
  });

  /// 本页路由常量（onPageResume 注册用；无路由上下文时同样安全）。
  final String location;

  final String title;
  final String subtitle;
  final String searchHint;

  /// 大类分段（调用方已按权限过滤；至少一段）。
  final List<WarehouseTaskSegmentSpec> segments;

  /// 当前选中分段的内容（小类行 + 表格）。
  final Widget Function(String segmentValue, String keyword, int refreshTick)
  bodyBuilder;

  /// 工具条尾挂（如「共 N 项」由各分段自带，一般不传）。
  final Widget Function(String segmentValue)? trailingBuilder;

  /// 返回本页时重拉计数 provider（分段徽章/上级 hub 角标用）。
  final VoidCallback? onResume;

  @override
  ConsumerState<WarehouseTaskCenterScaffold> createState() =>
      _WarehouseTaskCenterScaffoldState();
}

class _WarehouseTaskCenterScaffoldState
    extends ConsumerState<WarehouseTaskCenterScaffold> {
  // 进页面不预选任何大类（数据/内容不加载）；null = 未选择引导态。
  String? _segment;
  String _keyword = '';
  String? _myLocation;
  int _refreshTick = 0;

  /// onPageResume 首次触发是「进入本页」的导航结算，不是返回——跳过一次。
  bool _resumeArmed = false;

  @override
  void didUpdateWidget(WarehouseTaskCenterScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 权限变化导致当前分段被移除时，回到未选择引导态（保持「不预选」范式）。
    if (_segment != null && !widget.segments.any((s) => s.value == _segment)) {
      _segment = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _myLocation ??= currentLocationOr(context, widget.location);
    ref.onPageResume(_myLocation!, () {
      if (!_resumeArmed) {
        _resumeArmed = true;
        return;
      }
      setState(() => _refreshTick++);
      widget.onResume?.call();
    });
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.title,
        subtitle: widget.subtitle,
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.warehouse),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: () {
              setState(() => _refreshTick++);
              widget.onResume?.call();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: UtenContentContainer.wide(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenFilterToolbar<String>(
                  segmentsKey: Key(
                    'warehouse-task-center-segments-${widget.title}',
                  ),
                  searchKey: Key(
                    'warehouse-task-center-search-${widget.title}',
                  ),
                  segments: [
                    for (final segment in widget.segments)
                      UtenFilterSegment(
                        value: segment.value,
                        label: segment.label,
                        count: segment.count,
                      ),
                  ],
                  selected: _segment == null ? const <String>{} : {_segment!},
                  onSelectionChanged: (value) {
                    setState(() => _segment = value);
                  },
                  searchHint: widget.searchHint,
                  onSearchChanged: (value) {
                    setState(() => _keyword = value.trim());
                  },
                  trailing: widget.trailingBuilder?.call(_segment ?? ''),
                ),
                const SizedBox(height: UtenSpacing.s12),
                Expanded(
                  child: _segment == null
                      ? const _SegmentPlaceholder()
                      : widget.bodyBuilder(_segment!, _keyword, _refreshTick),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 大类未选时的内容区占位：进页面不预选，引导先选分类。
class _SegmentPlaceholder extends StatelessWidget {
  const _SegmentPlaceholder();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '请先在上方选择分类',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.touch_app_outlined,
              size: 40,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text('在上方选择分类后开始办理', style: theme.textTheme.titleSmall),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '分段右侧数字徽章为该分类的待办数量',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
