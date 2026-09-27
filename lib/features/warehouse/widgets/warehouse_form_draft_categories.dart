import 'package:flutter/material.dart';

import '../../../core/router/route_names.dart';
import '../../../shared/drafts/form_draft_category.dart';

/// Task-entry forms belong to their physical direction; manual stock documents
/// stay in their existing per-document 草稿 category.
const _inboundTaskDraftRoutes = {
  RouteName.warehouseArrivalReceiptNew,
  RouteName.warehouseArrivalReceiptBatch,
  RouteName.warehouseProductionFinishedArrivalRegistrationBase,
  RouteName.warehouseQualityResults,
};
const _outboundTaskDraftRoutes = {
  '/warehouse/subcontract-outbound/',
  '/warehouse/sales-outbound/',
};
const _drawTaskDraftRoutes = {
  RouteName.warehouseProductionDrawBatchIssue,
  '/warehouse/material-discovery/',
};
const warehouseInboundFormDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: _inboundTaskDraftRoutes,
);
const warehouseOutboundFormDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: _outboundTaskDraftRoutes,
);
const warehouseDrawFormDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: _drawTaskDraftRoutes,
);
const warehouseMasterFormDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefix: '/basicinfo/warehouse',
);

const warehouseInboundAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: {
    ..._inboundTaskDraftRoutes,
    '/warehouse/OTHER_IN/new',
    '/warehouse/FINISHED_IN/new',
  },
);
const warehouseOutboundAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: {
    ..._outboundTaskDraftRoutes,
    '/warehouse/OTHER_OUT/new',
    '/warehouse/FINISHED_OUT/new',
  },
);
const warehouseDrawAllDraftScope = FormDraftCategoryScope(
  module: BadgeModule.warehouse,
  routePrefixes: {..._drawTaskDraftRoutes, '/warehouse/DRAW/new'},
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
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      ?header,
      Expanded(
        child: FormDraftCategoryList(scope: scope, search: search),
      ),
    ],
  );
}
