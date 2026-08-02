import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/features/warehouse/pages/procurement_return_task_pages.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/procurement_inbound.dart';

void main() {
  test('arrival workflow routes keep department responsibilities separate', () {
    expect(requiredAnyPermFor(RouteName.warehouseInboundExpectations), [
      Perm.warehouseInboundView,
    ]);
    expect(requiredAnyPermFor(RouteName.warehouseArrivalExceptions), [
      Perm.warehouseInboundView,
    ]);
    expect(requiredAnyPermFor(RouteName.financeArrivalExceptions), [
      Perm.financeOrderApprovalView,
    ]);
    expect(
      requiredAnyPermFor('${RouteName.financeArrivalExceptions}/exception-1'),
      [Perm.financeOrderApprovalView],
    );
    expect(requiredAnyPermFor(RouteName.procurementArrivalExceptions), [
      Perm.procurementArrivalExceptionHandle,
    ]);
    expect(
      requiredAnyPermFor(
        '${RouteName.procurementArrivalExceptions}/exception-1',
      ),
      [Perm.procurementArrivalExceptionHandle],
    );
  });

  test(
    'supplier return permission and module filters match server contract',
    () {
      expect(
        Perm.procurementArrivalExceptionHandle,
        'supplier_return_task:handle',
      );
      expect(
        procurementReturnTasksLocation(ProcurementInboundOrderType.purchase),
        '/procurement/arrival-exceptions?orderType=PURCHASE',
      );
      expect(
        procurementReturnTasksLocation(ProcurementInboundOrderType.subcontract),
        '/procurement/arrival-exceptions?orderType=SUBCONTRACT',
      );
    },
  );

  test('finance and owner detail links are stable', () {
    expect(
      RoutePath.financeArrivalException('exception-1'),
      '/finance/procurement-arrival-exceptions/exception-1',
    );
    expect(
      RoutePath.procurementArrivalException('exception-1'),
      '/procurement/arrival-exceptions/exception-1',
    );
  });
}
