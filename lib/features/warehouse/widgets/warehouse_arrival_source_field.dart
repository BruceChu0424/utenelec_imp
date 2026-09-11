import 'package:flutter/material.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';

/// The server resolves automatic arrivals only when the source is unambiguous.
enum WarehouseArrivalSource {
  automatic(null),
  normal('NORMAL'),
  replacementFirst('RETURN_REPLACEMENT');

  const WarehouseArrivalSource(this.apiValue);

  final String? apiValue;

  String label(BuildContext context) {
    final text = workflowFieldText(context);
    return switch (this) {
      automatic => text.warehouseArrivalSourceAutomatic,
      normal => text.warehouseArrivalSourceNormal,
      replacementFirst => text.warehouseArrivalSourceReplacement,
    };
  }
}

class WarehouseArrivalSourceField extends StatelessWidget {
  const WarehouseArrivalSourceField({
    super.key,
    required this.value,
    required this.onChanged,
    required this.enabled,
  });

  final WarehouseArrivalSource value;
  final ValueChanged<WarehouseArrivalSource> onChanged;
  final bool enabled;

  // 列级通用说明（warehouseArrivalSourceHint）挂在表头 ⓘ 上（2026-09-10 全站
  // 口径：格内只留行特有的错误/预填图标），故这里不传 info。
  @override
  Widget build(BuildContext context) => UtenDropdownField(
    value: value.name,
    enabled: enabled,
    allowClear: false,
    searchable: false,
    items: [
      for (final source in WarehouseArrivalSource.values)
        UtenDropdownItem(value: source.name, label: source.label(context)),
    ],
    onChanged: (selected) {
      if (selected == null) return;
      onChanged(WarehouseArrivalSource.values.byName(selected));
    },
  );
}
