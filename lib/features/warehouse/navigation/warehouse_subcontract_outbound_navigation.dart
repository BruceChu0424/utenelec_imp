import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/route_names.dart';

/// A successful warehouse operation has an explicit destination, including
/// when its detail was opened from a deep link or a legacy standalone list.
const subcontractOutboundCompletedLocation =
    '${RouteName.warehouseOutboundTasks}?section=subcontract&view=tasks';

void returnToSubcontractOutboundTasks(BuildContext context) =>
    context.go(subcontractOutboundCompletedLocation);
