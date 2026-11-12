import 'package:flutter/material.dart';

import '../../../shared/drafts/form_draft_category.dart';

/// Independent draft workspaces are reserved for new documents and masters.
/// Task-entry snapshots are presented and resumed on their original task rows.
const warehouseMasterFormDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefix: '/basicinfo/warehouse',
);

const warehouseInboundAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  excludeTaskDrafts: true,
  routePrefixes: {'/warehouse/OTHER_IN/new', '/warehouse/FINISHED_IN/new'},
);
const warehouseOutboundAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  excludeTaskDrafts: true,
  routePrefixes: {'/warehouse/OTHER_OUT/new', '/warehouse/FINISHED_OUT/new'},
);
const warehouseDrawAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  excludeTaskDrafts: true,
  routePrefixes: {'/warehouse/DRAW/new'},
);

class WarehouseFormDraftCategory extends StatelessWidget {
  const WarehouseFormDraftCategory({
    super.key,
    required this.scope,
    this.header,
    this.search = '',
  });
  final FormDraftCategoryScope scope;
  final Widget? header;
  final String search;

  @override
  Widget build(BuildContext context) => FormDraftCategoryList(
    scope: scope,
    search: search,
    // 搜索框由宿主任务中心分类栏同行承担（search 即宿主关键词，2026-11-11
    // 宽屏同排口径），这里不再自建独占一行的重复搜索框。
    showSearch: false,
    // 大类/小类前缀行挂进草稿列表自己的折叠头随上滑收走（2026-09-29
    // 用户口径「上滑先把表格顶到最上面」——与其他分段视图同一 externalHeader 链）。
    externalHeader: header,
  );
}
