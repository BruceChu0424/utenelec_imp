// 仓库任务中心的「仓库范围」(ADR-115, 2026-09-24)。
//
// 用户原话：「多个仓库由多个人员负责，但仓库的通知是统一全部收到的……没有一个快速找到
// 自己仓库相关单据的方法」。仓库资料里给每个仓登记负责人(仓管员)后：
//   · 仓库类通知只发给单据所在仓的负责人(服务端 ChainNoticeService, 没登记负责人的仓照旧全员收)；
//   · 出库 / 入库 / 生产领料三个任务中心顶部多一个「仓库范围」选择：
//       我的仓库 —— 我负责的仓(含子仓) + 还没指定负责人的仓 + 还没定仓的任务(与通知同口径,
//                   不会有单据掉进无人区)；
//       全部仓库 —— 不过滤；
//       某个仓   —— 只看该仓(含子仓)，替同事顶班时用。
//   · 选择按账号记忆(user_preferences: warehouse.taskScope)；从没选过时，登记为负责人的账号
//     默认「我的仓库」，其余默认「全部仓库」。
// 范围只决定列表显示哪些单据，不改权限：各列表照旧按服务端权限与对象范围校验。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import '../providers/authenticated_scope_provider.dart';
import '../providers/uten_page_prefs_notifier.dart';

/// 一个仓库(范围选择器的选项 / 我负责的仓)。
@immutable
class WarehouseScopeOption {
  const WarehouseScopeOption({
    required this.id,
    required this.name,
    this.code,
    this.parentId,
  });

  final String id;
  final String name;
  final String? code;
  final String? parentId;

  factory WarehouseScopeOption.fromJson(Map<String, dynamic> json) =>
      WarehouseScopeOption(
        id: json['id'].toString(),
        name: (json['name'] as String?)?.trim().isNotEmpty == true
            ? (json['name'] as String).trim()
            : (json['code']?.toString() ?? '未命名仓库'),
        code: json['code']?.toString(),
        parentId: json['parentId']?.toString(),
      );
}

/// 当前账号的「我的仓库」(GET /master/warehouses/my-scope)。
@immutable
class MyWarehouseScope {
  const MyWarehouseScope({
    this.keeperWarehouses = const [],
    this.scopeWarehouseIds = const {},
    this.keepersConfigured = false,
  });

  static const empty = MyWarehouseScope();

  /// 本人被登记为负责人的仓(登记在主仓上的只列主仓)。
  final List<WarehouseScopeOption> keeperWarehouses;

  /// 「我的仓库」实际范围(含子仓与尚无负责人的仓)。
  final Set<String> scopeWarehouseIds;

  /// 全公司是否登记过任何负责人。
  final bool keepersConfigured;

  bool get isKeeper => keeperWarehouses.isNotEmpty;

  factory MyWarehouseScope.fromJson(Map<String, dynamic> json) {
    final keepers = json['keeperWarehouses'];
    final scope = json['scopeWarehouseIds'];
    return MyWarehouseScope(
      keeperWarehouses: [
        if (keepers is List)
          for (final item in keepers)
            if (item is Map)
              WarehouseScopeOption.fromJson(item.cast<String, dynamic>()),
      ],
      scopeWarehouseIds: {
        if (scope is List)
          for (final id in scope)
            if (id != null) id.toString(),
      },
      keepersConfigured: json['keepersConfigured'] == true,
    );
  }
}

/// 范围选择的三种模式。
enum WarehouseTaskScopeMode { all, mine, warehouse }

/// 列表请求用的仓库范围。
@immutable
class WarehouseTaskScope {
  const WarehouseTaskScope._(this.mode, this.warehouseId, this.warehouseName);

  const WarehouseTaskScope.all()
    : this._(WarehouseTaskScopeMode.all, null, null);

  const WarehouseTaskScope.mine()
    : this._(WarehouseTaskScopeMode.mine, null, null);

  const WarehouseTaskScope.warehouse(String id, {String? name})
    : this._(WarehouseTaskScopeMode.warehouse, id, name);

  final WarehouseTaskScopeMode mode;
  final String? warehouseId;
  final String? warehouseName;

  bool get isAll => mode == WarehouseTaskScopeMode.all;

  /// 附到列表请求上的参数(各仓库任务中心端点同名)：
  /// `warehouseScope=MINE` 或 `scopeWarehouseId=<id>`；全部仓库不带参数。
  Map<String, String> get queryParameters => switch (mode) {
    WarehouseTaskScopeMode.all => const {},
    WarehouseTaskScopeMode.mine => const {'warehouseScope': 'MINE'},
    WarehouseTaskScopeMode.warehouse => {'scopeWarehouseId': warehouseId!},
  };

  @override
  bool operator ==(Object other) =>
      other is WarehouseTaskScope &&
      other.mode == mode &&
      other.warehouseId == warehouseId;

  @override
  int get hashCode => Object.hash(mode, warehouseId);
}

/// 账号记忆的范围选择；[mode] 为 null = 从没选过(按是否负责人自动)。
@immutable
class WarehouseTaskScopePref {
  const WarehouseTaskScopePref({this.mode, this.warehouseId});

  static const unset = WarehouseTaskScopePref();

  final WarehouseTaskScopeMode? mode;
  final String? warehouseId;
}

class WarehouseTaskScopePrefNotifier
    extends UtenPagePrefsNotifier<WarehouseTaskScopePref> {
  @override
  String get prefKey => 'warehouse.taskScope';

  @override
  WarehouseTaskScopePref get defaultValue => WarehouseTaskScopePref.unset;

  @override
  WarehouseTaskScopePref? decode(Object? raw) {
    if (raw is! Map) return null;
    final mode = switch (raw['mode']) {
      'ALL' => WarehouseTaskScopeMode.all,
      'MINE' => WarehouseTaskScopeMode.mine,
      'WAREHOUSE' => WarehouseTaskScopeMode.warehouse,
      _ => null,
    };
    final warehouseId = raw['warehouseId'];
    if (mode == WarehouseTaskScopeMode.warehouse &&
        (warehouseId is! String || warehouseId.trim().isEmpty)) {
      return WarehouseTaskScopePref.unset;
    }
    return WarehouseTaskScopePref(
      mode: mode,
      warehouseId: mode == WarehouseTaskScopeMode.warehouse
          ? (warehouseId as String).trim()
          : null,
    );
  }

  @override
  Object? encode(WarehouseTaskScopePref state) => switch (state.mode) {
    null => const {},
    WarehouseTaskScopeMode.all => const {'mode': 'ALL'},
    WarehouseTaskScopeMode.mine => const {'mode': 'MINE'},
    WarehouseTaskScopeMode.warehouse => {
      'mode': 'WAREHOUSE',
      'warehouseId': state.warehouseId,
    },
  };

  /// 用户在范围选择器里明确选了一项。
  void select(WarehouseTaskScope scope) {
    update(
      WarehouseTaskScopePref(mode: scope.mode, warehouseId: scope.warehouseId),
    );
  }
}

final warehouseTaskScopePrefProvider =
    NotifierProvider<WarehouseTaskScopePrefNotifier, WarehouseTaskScopePref>(
      WarehouseTaskScopePrefNotifier.new,
    );

/// 当前账号的「我的仓库」。随身份重建；失败按「不是负责人」处理(默认全部仓库, 不挡页面)。
final myWarehouseScopeProvider = FutureProvider<MyWarehouseScope>((ref) async {
  final scope = ref.watch(authenticatedScopeProvider);
  if (scope == null) return MyWarehouseScope.empty;
  try {
    final json = await ref
        .read(apiClientProvider)
        .get(ApiEndpoints.myWarehouseScope);
    return MyWarehouseScope.fromJson(json);
  } catch (_) {
    return MyWarehouseScope.empty;
  }
});

/// 范围选择器里的仓库清单(未删除的全部仓, 按编号)。
final warehouseScopeOptionsProvider =
    FutureProvider<List<WarehouseScopeOption>>((ref) async {
      final scope = ref.watch(authenticatedScopeProvider);
      if (scope == null) return const [];
      final list = await ref
          .read(apiClientProvider)
          .getList(ApiEndpoints.warehousesDict);
      return [for (final item in list) WarehouseScopeOption.fromJson(item)];
    });

/// 仓库任务中心各列表当前生效的范围。
///
/// 从没选过：负责人默认「我的仓库」、其余「全部仓库」(「我的仓库」还没加载完时先按全部,
/// 加载完再切, 各列表随之重拉一次)。选过就按记忆; 记忆里的仓已被删除时回到全部仓库。
final warehouseTaskScopeProvider = Provider<WarehouseTaskScope>((ref) {
  final pref = ref.watch(warehouseTaskScopePrefProvider);
  switch (pref.mode) {
    case WarehouseTaskScopeMode.all:
      return const WarehouseTaskScope.all();
    case WarehouseTaskScopeMode.mine:
      return const WarehouseTaskScope.mine();
    case WarehouseTaskScopeMode.warehouse:
      final options = ref.watch(warehouseScopeOptionsProvider).valueOrNull;
      final id = pref.warehouseId!;
      if (options == null) return WarehouseTaskScope.warehouse(id);
      for (final option in options) {
        if (option.id == id) {
          return WarehouseTaskScope.warehouse(id, name: option.name);
        }
      }
      return const WarehouseTaskScope.all();
    case null:
      final mine = ref.watch(myWarehouseScopeProvider).valueOrNull;
      return mine != null && mine.isKeeper
          ? const WarehouseTaskScope.mine()
          : const WarehouseTaskScope.all();
  }
});

/// 仓库任务中心把当前范围往下传给各分段列表(出库/入库/领料三个任务中心的骨架包一层)。
///
/// 同一批列表视图也被单独页面复用(库存单据列表、销售出库页等)，那里没有这一层，
/// [of] 返回「全部仓库」，不受任务中心的选择影响。范围变化时骨架会推进 refreshTick，
/// 各列表照旧按 refreshTick 重拉，重拉时再用 [of] 读最新范围(不建立依赖, 不多重建一次)。
class WarehouseListScope extends InheritedWidget {
  const WarehouseListScope({
    super.key,
    required this.scope,
    required super.child,
  });

  final WarehouseTaskScope scope;

  static WarehouseTaskScope of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<WarehouseListScope>()?.scope ??
      const WarehouseTaskScope.all();

  @override
  bool updateShouldNotify(WarehouseListScope oldWidget) =>
      oldWidget.scope != scope;
}
