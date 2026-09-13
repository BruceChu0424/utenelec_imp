import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/warehouse_iqc_stock_in.dart'
    show WarehouseIqcStockInConfirmItem;
import '../models/warehouse_quality_result.dart';

/// 单据详情和批量入库共用的放行切片草稿。按放行 UUID 保存输入，
/// 每个切片独立选择本次实际叶仓，刷新不会把不同来源或分仓合并。
class WarehouseQualitySliceDraft {
  WarehouseQualitySliceDraft(
    this.slice, {
    this.receiptTypeValue,
    this.receiptId,
    this.receiptNo,
    this.canConfirm = true,
    WarehouseQualitySliceSnapshot? snapshot,
  }) : selected = canConfirm && (snapshot?.selected ?? true),
       quantity = TextEditingController(
         text:
             snapshot?.quantity ??
             warehouseQualityQuantity(slice.remainingBaseQty),
       ),
       place = TextEditingController(
         text: snapshot?.place ?? slice.placeHint ?? '',
       ),
       _warehouseId = snapshot == null
           ? slice.warehouseId
           : snapshot.warehouseId,
       _warehouseName = snapshot == null
           ? slice.warehouseName
           : snapshot.warehouseName,
       _placeRequiresReview = snapshot?.placeRequiresReview ?? false;

  final WarehouseQualityReleasedSlice slice;
  final String? receiptTypeValue;
  final String? receiptId;
  final String? receiptNo;
  final bool canConfirm;
  bool selected;
  final TextEditingController quantity;
  final TextEditingController place;
  String? _warehouseId;
  String? _warehouseName;
  bool _placeRequiresReview;

  String? get warehouseId => _warehouseId;
  String? get warehouseName => _warehouseName;

  /// 库位属于实际叶仓。改仓必须重新核对位置；选同一个 UUID 仅更新显示名，
  /// 不清空已经填写的库位。刷新走 snapshot，不属于人工改仓。
  bool selectWarehouse({required String id, required String name}) {
    final changed = id != _warehouseId;
    _warehouseId = id;
    _warehouseName = name;
    if (changed) {
      _placeRequiresReview = true;
      place.clear();
    }
    return changed;
  }

  String get placeInputHint =>
      _placeRequiresReview ? '请重新填写实际库位' : slice.placeHint ?? '实际库位';

  String get receiptKey => '$receiptTypeValue:$receiptId';
  String get snapshotKey => '$receiptKey:${slice.passEventId}';
  String get goodsLabel =>
      slice.goodsLabel.isEmpty ? slice.passEventId : slice.goodsLabel;
  bool get usesSuggestedWarehouse =>
      warehouseId != null && warehouseId == slice.warehouseId;
  double get previewQuantity {
    final value = double.tryParse(quantity.text.trim());
    return value != null && value.isFinite && value > 0 ? value : 0;
  }

  WarehouseQualitySliceSnapshot get snapshot => WarehouseQualitySliceSnapshot(
    selected: selected,
    quantity: quantity.text,
    place: place.text,
    warehouseId: warehouseId,
    warehouseName: warehouseName,
    placeRequiresReview: _placeRequiresReview,
  );

  String? get quantityError {
    final value = double.tryParse(quantity.text.trim());
    if (value == null || !value.isFinite || value < 0.0001) {
      return '请输入不小于 0.0001 的本次实收数量';
    }
    if (value - slice.remainingBaseQty > 0.0000001) {
      return '本次数量 ${warehouseQualityQuantity(value)} 不得超过合格待入量 '
          '${warehouseQualityQuantity(slice.remainingBaseQty)}';
    }
    final scaled = value * 10000;
    if (!scaled.isFinite ||
        (scaled - scaled.roundToDouble()).abs() > 0.000001) {
      return '本次实收数量最多保留 4 位小数';
    }
    return null;
  }

  String? get warehouseError =>
      warehouseId?.trim().isNotEmpty == true ? null : '请选择本次实际入库的目标叶仓';

  String? get placeError {
    if (place.text.trim().isEmpty) {
      return _placeRequiresReview ? '目标仓库已更换，请重新填写实际库位' : '请填写本次实际库位';
    }
    if (place.text.trim().length > 100) return '实际库位不得超过 100 个字符';
    return null;
  }

  String? validate() {
    if (!selected) return null;
    if (!canConfirm) return '「$goodsLabel」当前已不可入库，请刷新后核对';
    final error = quantityError ?? warehouseError ?? placeError;
    return error == null ? null : '「$goodsLabel」$error';
  }

  WarehouseIqcStockInConfirmItem toConfirmItem() =>
      WarehouseIqcStockInConfirmItem(
        passEventId: slice.passEventId,
        baseQty: double.parse(quantity.text.trim()),
        expectedRemainingBaseQty: slice.remainingBaseQty,
        warehouseId: warehouseId!,
        place: place.text.trim(),
      );

  void dispose() {
    quantity.dispose();
    place.dispose();
  }
}

class WarehouseQualitySliceSnapshot {
  const WarehouseQualitySliceSnapshot({
    required this.selected,
    required this.quantity,
    required this.place,
    this.warehouseId,
    this.warehouseName,
    this.placeRequiresReview = false,
  });

  final bool selected;
  final String quantity;
  final String place;
  final String? warehouseId;
  final String? warehouseName;
  final bool placeRequiresReview;
}

String warehouseQualitySliceFingerprint(
  List<WarehouseIqcStockInConfirmItem> items,
) {
  final sorted = [...items]
    ..sort((left, right) => left.passEventId.compareTo(right.passEventId));
  return jsonEncode([for (final item in sorted) item.toJson()]);
}

String warehouseQualityQuantity(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String warehouseQualityDateTime(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  final normalized = text.replaceFirst('T', ' ');
  return normalized.length > 16 ? normalized.substring(0, 16) : normalized;
}
