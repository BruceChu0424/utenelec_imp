// 仓库数据范围(ADR-149, 取代 ADR-115 的「我的仓库」可选筛选)。
//
// 谁能看哪些仓由服务端唯一判定(GET /master/warehouses/my-scope 告诉前端结论):
//   · 主管(超管、仓储部负责人、登记在主仓上的负责人)：默认看全部，可挑任一仓(含下级)；
//   · 子仓负责人：只看自己负责的仓，负责多个仓时可以在这几个仓之间切换；
//   · 其他人：看没人负责的仓与未定仓的任务，不能挑仓。
// 各任务列表、facets、分段计数与徽章都由服务端按本人范围强制过滤；前端只多带一个可选的
// scopeWarehouseId(在可选范围内挑一个仓)，越界服务端返回 403。
// 选择按账号记忆(user_preferences: warehouse.taskScope，只存 warehouseId)；记忆的仓不在
// 当前可选范围内(负责关系变了、仓被删)时回到本人默认范围。
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
            : (json['code']?.toString() ?? ''),
        code: json['code']?.toString(),
        parentId: json['parentId']?.toString(),
      );
}

/// 服务端判定的角色。
enum WarehouseScopeRole { supervisor, keeper, other }

/// 当前账号的仓库数据范围(GET /master/warehouses/my-scope)。
@immutable
class MyWarehouseScope {
  const MyWarehouseScope({
    this.role = WarehouseScopeRole.other,
    this.canSelectAll = false,
    this.selectable = const [],
    this.keeperWarehouses = const [],
    this.defaultWarehouseId,
  });

  static const empty = MyWarehouseScope();

  final WarehouseScopeRole role;

  /// 能选「全部仓库」(只有主管)。
  final bool canSelectAll;

  /// 可以切换到的仓(主管 = 全部在用仓，先主仓后子仓；子仓负责人 = 自己负责的仓及下级)。
  final List<WarehouseScopeOption> selectable;

  /// 本人登记负责的仓(登记在主仓上的也列出)。
  final List<WarehouseScopeOption> keeperWarehouses;

  /// 只负责一个仓的子仓负责人 = 那个仓；其余为空。
  final String? defaultWarehouseId;

  bool get isSupervisor => role == WarehouseScopeRole.supervisor;

  bool get isKeeper => role == WarehouseScopeRole.keeper;

  /// 选择器只对主管或负责多个仓的人出现。
  bool get showsSelector => isSupervisor || (isKeeper && selectable.length > 1);

  /// 只负责一个仓：顶栏显示只读标签「我负责：包材仓库」。
  WarehouseScopeOption? get onlyWarehouse =>
      isKeeper && selectable.length == 1 ? selectable.single : null;

  bool canSelect(String warehouseId) =>
      selectable.any((option) => option.id == warehouseId);

  WarehouseScopeOption? option(String warehouseId) {
    for (final option in selectable) {
      if (option.id == warehouseId) return option;
    }
    return null;
  }

  factory MyWarehouseScope.fromJson(Map<String, dynamic> json) {
    List<WarehouseScopeOption> options(Object? raw) => [
      if (raw is List)
        for (final item in raw)
          if (item is Map)
            WarehouseScopeOption.fromJson(item.cast<String, dynamic>()),
    ];
    return MyWarehouseScope(
      role: switch (json['role']) {
        'SUPERVISOR' => WarehouseScopeRole.supervisor,
        'KEEPER' => WarehouseScopeRole.keeper,
        _ => WarehouseScopeRole.other,
      },
      canSelectAll: json['canSelectAll'] == true,
      selectable: options(json['selectable']),
      keeperWarehouses: options(json['keeperWarehouses']),
      defaultWarehouseId: json['defaultWarehouseId']?.toString(),
    );
  }
}

/// 列表请求用的仓库范围：[all] = 本人默认范围(不带参数，服务端按本人范围过滤)；
/// [warehouse] = 在可选范围内挑的一个仓(带 scopeWarehouseId)。
@immutable
class WarehouseTaskScope {
  const WarehouseTaskScope._(this.warehouseId, this.warehouseName);

  const WarehouseTaskScope.all() : this._(null, null);

  const WarehouseTaskScope.warehouse(String id, {String? name})
    : this._(id, name);

  final String? warehouseId;
  final String? warehouseName;

  bool get isAll => warehouseId == null;

  /// 附到列表 / 计数请求上的参数(各仓库任务端点同名)。
  Map<String, String> get queryParameters =>
      isAll ? const {} : {'scopeWarehouseId': warehouseId!};

  @override
  bool operator ==(Object other) =>
      other is WarehouseTaskScope && other.warehouseId == warehouseId;

  @override
  int get hashCode => warehouseId.hashCode;
}

/// 账号记忆的范围选择：[warehouseId] 为 null = 本人默认范围。
@immutable
class WarehouseTaskScopePref {
  const WarehouseTaskScopePref({this.warehouseId});

  static const unset = WarehouseTaskScopePref();

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
    // ADR-115 的旧偏好({mode: MINE/ALL/WAREHOUSE})不再有意义, 一律回到默认范围。
    final warehouseId = raw['warehouseId'];
    if (raw.containsKey('mode') && raw['mode'] != 'WAREHOUSE') {
      return WarehouseTaskScopePref.unset;
    }
    return warehouseId is String && warehouseId.trim().isNotEmpty
        ? WarehouseTaskScopePref(warehouseId: warehouseId.trim())
        : WarehouseTaskScopePref.unset;
  }

  @override
  Object? encode(WarehouseTaskScopePref state) =>
      state.warehouseId == null ? const {} : {'warehouseId': state.warehouseId};

  /// 用户在范围选择器里明确选了一项(全部 = 回到本人默认范围)。
  void select(WarehouseTaskScope scope) {
    update(WarehouseTaskScopePref(warehouseId: scope.warehouseId));
  }
}

final warehouseTaskScopePrefProvider =
    NotifierProvider<WarehouseTaskScopePrefNotifier, WarehouseTaskScopePref>(
      WarehouseTaskScopePrefNotifier.new,
    );

/// 当前账号的仓库数据范围。随身份重建；失败按「其他人」处理(不显示选择器, 列表仍由服务端过滤)。
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

/// 仓库任务中心各列表当前生效的范围。
///
/// 没选过 = 本人默认范围。记忆的仓只有仍在可选范围内才生效(负责关系变了 / 仓被删 → 回到默认),
/// 可选范围还没加载完时先按默认, 加载完再切, 各列表随之重拉一次。
final warehouseTaskScopeProvider = Provider<WarehouseTaskScope>((ref) {
  final pref = ref.watch(warehouseTaskScopePrefProvider);
  final id = pref.warehouseId;
  if (id == null) return const WarehouseTaskScope.all();
  final mine = ref.watch(myWarehouseScopeProvider).valueOrNull;
  if (mine == null || !mine.showsSelector) {
    return const WarehouseTaskScope.all();
  }
  final option = mine.option(id);
  return option == null
      ? const WarehouseTaskScope.all()
      : WarehouseTaskScope.warehouse(id, name: option.name);
});

/// 仓库任务中心把当前范围往下传给各分段列表(出库/入库/生产领料三个任务中心的骨架包一层)。
///
/// 同一批列表视图也被单独页面复用(库存单据列表、销售出库页等)，那里没有这一层，
/// [of] 返回本人默认范围(不带参数，服务端照样按本人范围过滤)。范围变化时骨架会推进
/// refreshTick，各列表照旧按 refreshTick 重拉，重拉时再用 [of] 读最新范围(不建立依赖)。
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
