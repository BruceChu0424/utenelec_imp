// 委外模块 Providers：状态徽章文案/配色 + 主档名称解析（复用采购的 MasterNameService）。
//
// 委外商 = suppliers（采购/委外共用同一主档），货品/颜色/单位/仓库/币种也都是基础资料主档，
// 因此直接 re-export 采购模块的 masterNameServiceProvider / GoodsOption，避免重复缓存与二次加载。
import 'package:flutter/material.dart';

import '../models/subcontract_doc.dart';

// 复用采购的主档名称解析（supplier/warehouse/currency/color/unit/goods）。
export '../../purchase/providers/master_name_provider.dart'
    show masterNameServiceProvider, GoodsOption;

/// 委外单据状态文案（0草稿/1已审/-1红冲）。
String subcontractStatusLabel(int? code) {
  switch (code) {
    case kSubcontractStatusDraft:
      return '草稿';
    case kSubcontractStatusApproved:
      return '已审';
    case kSubcontractStatusReversed:
      return '红冲';
    default:
      return '—';
  }
}

/// 委外单据状态主题色（徽章用）。
Color subcontractStatusColor(int? code, ThemeData theme) {
  switch (code) {
    case kSubcontractStatusDraft:
      return theme.colorScheme.onSurfaceVariant;
    case kSubcontractStatusApproved:
      return Colors.green;
    case kSubcontractStatusReversed:
      return theme.colorScheme.error;
    default:
      return theme.colorScheme.onSurfaceVariant;
  }
}
