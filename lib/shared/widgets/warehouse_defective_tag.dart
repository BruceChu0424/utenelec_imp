// 不良品仓标签(ADR-146)：选仓面板、库存余额、货品详情里凡是不良品仓都带它，
// 让人一眼知道这里的货不计入可用量、只经专门通道进出。
import 'package:flutter/material.dart';

import '../../components/data_display/uten_status_badge.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';

/// 选仓相关文案；没挂本地化的轻量宿主(共享组件单测)回落中文。
AppLocalizations warehouseL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ??
    AppLocalizationsZh();

class WarehouseDefectiveTag extends StatelessWidget {
  const WarehouseDefectiveTag({super.key});

  @override
  Widget build(BuildContext context) => UtenStatusBadge(
    label: warehouseL10n(context).warehouseDefectiveTag,
    type: UtenStatusBadgeType.danger,
    size: UtenStatusBadgeSize.small,
  );
}

/// 良品用途下不良品仓置灰时的一句说明。
String warehouseDefectiveBlockedHint(BuildContext context) =>
    warehouseL10n(context).warehouseDefectiveBlockedHint;
