// 入库登记的共用模型(2026-09-27 用户口径「产成品入库与采购/委外入库的 UI、逻辑、
// 表格、记忆都应该一样，能公用的都公用」)：
//   - [InboundRoute]：两条入库路线的名字、图标、说明与路由参数(任务中心按钮、批量页
//     提交按钮、单张页两个按钮、确认弹窗全从这里取，保证同名同义)；
//   - [InboundRegistrationLine]：一行登记明细的「入库仓库 + 库位号」状态与改仓/回填
//     建议/批量写库位规则(两类登记页的行模型都继承它)；
//   - [InboundPlaceSuggestionLoader]：按仓合并请求库位建议、只覆盖没手填过的行。
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/network/api_exception.dart';
import '../repositories/warehouse_place_suggestion_repository.dart';

/// 入库两条路线：点哪条就走哪条，页面上两条路线始终用同一对名字。
enum InboundRoute {
  /// 登记同一事务把实物按库位先上架，品质部到库位检验；合格由系统按上架位置自动
  /// 转正入库，仓库不再点第二次(需独立权限)。
  stockInFirst(
    label: '先入库后质检',
    icon: Icons.shelves,
    hint: '登记的同时把每行实物按库位上架，品质部到库位检验；合格由系统按上架位置自动转正入库',
  ),

  /// 登记后送品质部检验，合格后仓库再核对实物与库位确认入库。
  inspectFirst(
    label: '先质检后入库',
    icon: Icons.fact_check_outlined,
    hint: '登记后送品质部检验，合格后仓库再核对实物与库位确认入库',
  );

  const InboundRoute({
    required this.label,
    required this.icon,
    required this.hint,
  });

  final String label;
  final IconData icon;
  final String hint;

  bool get isStockInFirst => this == InboundRoute.stockInFirst;

  /// 批量登记页路由参数：`?preStock=1` = 先入库后质检；不带 = 先质检后入库。
  static const queryKey = 'preStock';

  static InboundRoute fromQuery(Map<String, String> query) =>
      query[queryKey] == '1' ? stockInFirst : inspectFirst;

  /// 把路线挂到批量登记页地址上(已有 query 时追加)。
  String appendTo(String location) {
    if (!isStockInFirst) return location;
    return '$location${location.contains('?') ? '&' : '?'}$queryKey=1';
  }

  /// 提交按钮键(两类登记页同一套，测试与自动化按路线取按钮)。
  Key get submitKey => Key('inbound-route-submit-$name');

  /// 任务中心多选按钮键。
  Key get batchKey => Key('inbound-route-batch-$name');
}

/// 一行入库登记明细的「入库仓库 + 库位号」公共状态。
///
/// 规则(两类登记页一致)：
///   - 仓库预填(来源默认仓 / 上次所选仓)一律黄框待核对，用户一改即清标；
///   - 改仓：库位清空(库位属于仓库)，等新仓的库位建议回填；
///   - 库位建议只覆盖没手填过的行(空值或黄框预填)，回填后黄框待核对；
///   - 批量写库位(右键或勾选多行后改一行)视同已核对，不留黄框。
abstract class InboundRegistrationLine extends EditableGridRow {
  InboundRegistrationLine({
    String? warehouseId,
    bool warehouseAutofilled = false,
    String place = '',
    bool placeAutofilled = true,
    this.placeSource = InboundPlaceSource.none,
  }) : warehouse = ValueNotifier<String?>(warehouseId),
       place = UtenAutofillTextController(
         text: place,
         autofilled: placeAutofilled,
       ) {
    this.warehouseAutofilled =
        warehouseAutofilled && (warehouseId?.isNotEmpty ?? false);
  }

  String get goodsId;
  String? get colorId;
  String get goodsName;

  /// 只读行(已登记的成品报工行)：不参与改仓、建议与批量写值。
  bool get locked => false;

  /// 行级入库仓库(必填)。
  final ValueNotifier<String?> warehouse;
  String? get warehouseId => warehouse.value;

  /// 仓库是预填值(黄框待核对)。
  bool warehouseAutofilled = false;

  /// 库位号：[UtenAutofillTextController.autofilled] = 预填/建议值待核对。
  final UtenAutofillTextController place;

  /// 当前预填库位的来源(黄框说明用)。
  InboundPlaceSource placeSource;

  /// 用户手填过库位(非空且不是预填)：建议不再覆盖。
  bool get placeIsManual => place.text.trim().isNotEmpty && !place.autofilled;

  /// 改仓。[autofilled] = 预填(黄框)；用户显式选择传 false。
  /// 库位属于仓库：换了仓，原仓的库位(含手填的)一律清掉，等新仓的建议回填。
  void setWarehouse(String? warehouseId, {bool autofilled = false}) {
    if (locked) return;
    warehouseAutofilled = autofilled && (warehouseId?.isNotEmpty ?? false);
    if (warehouse.value == warehouseId) return;
    warehouse.value = warehouseId;
    // 先改来源再改文本：控制器一通知，格内黄标说明就按新来源重绘。
    placeSource = InboundPlaceSource.none;
    place.setAutomaticText('');
  }

  /// 回填库位建议(手填过的行不动；建议为空则清掉旧仓的预填值)。
  void applyPlaceSuggestion(WarehousePlaceSuggestion? suggestion) {
    if (locked || placeIsManual) return;
    placeSource = suggestion?.source ?? InboundPlaceSource.none;
    place.setAutomaticText(suggestion?.place ?? '');
  }

  /// 批量写库位：视同已核对，写完不留黄框。同值写入时控制器不会自行清标
  /// (只在文本变化时清)，故先置空再写回。
  void setCheckedPlace(String value) {
    if (locked) return;
    if (place.text == value) place.value = TextEditingValue.empty;
    place.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  @override
  void dispose() {
    warehouse.dispose();
    place.dispose();
    super.dispose();
  }
}

/// 按仓合并拉库位建议(同仓全部行一个请求)，只回填没手填过的行。
///
/// 页面持有一个实例并监听它(loading / error 驱动提示条与提交按钮置灰)；
/// 后发起的一轮会作废前一轮尚未返回的结果，避免旧仓的建议盖到新仓上。
class InboundPlaceSuggestionLoader extends ChangeNotifier {
  InboundPlaceSuggestionLoader(this._repository);

  final WarehousePlaceSuggestionRepository _repository;
  int _generation = 0;
  bool _disposed = false;

  bool loading = false;
  String? error;

  /// [lines] = 需要刷新建议的行(通常是刚改过仓的行，或进页时的全部行)。
  Future<void> reload(Iterable<InboundRegistrationLine> lines) async {
    final generation = ++_generation;
    final byWarehouse = <String, List<InboundRegistrationLine>>{};
    for (final line in lines) {
      final warehouseId = line.warehouseId;
      if (line.locked || line.placeIsManual) continue;
      if (warehouseId == null || warehouseId.isEmpty) continue;
      byWarehouse.putIfAbsent(warehouseId, () => []).add(line);
    }
    if (byWarehouse.isEmpty) {
      _set(loading: false, error: null);
      return;
    }
    _set(loading: true, error: null);
    String? firstError;
    for (final entry in byWarehouse.entries) {
      try {
        final suggestions = await _repository.suggest(
          warehouseId: entry.key,
          goods: [
            for (final line in entry.value)
              (goodsId: line.goodsId, colorId: line.colorId),
          ],
        );
        if (_disposed || generation != _generation) return;
        for (final line in entry.value) {
          // 等待期间用户改了仓的行不回填(下一轮会带上它)。
          if (line.warehouseId != entry.key) continue;
          line.applyPlaceSuggestion(
            suggestions[inboundGoodsColorKey(line.goodsId, line.colorId)],
          );
        }
      } on ApiException catch (error) {
        if (_disposed || generation != _generation) return;
        firstError ??= '库位建议加载失败：${error.message}(可重试或直接填写)';
      } catch (_) {
        if (_disposed || generation != _generation) return;
        firstError ??= '库位建议加载失败，可重试或直接填写';
      }
    }
    if (_disposed || generation != _generation) return;
    _set(loading: false, error: firstError);
  }

  void _set({required bool loading, required String? error}) {
    if (_disposed) return;
    this.loading = loading;
    this.error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
