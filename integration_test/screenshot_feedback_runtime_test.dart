// Production widgets on the actual Windows engine; all API fixtures remain
// local to the suites and never connect to the company service.
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/features/sales/pages/sales_doc_edit_v187_test.dart' as editor;
import '../test/features/sales/pages/sales_doc_detail_columns_test.dart'
    as detail;
import '../test/features/sales/pages/sales_shipment_task_workbench_test.dart'
    as shipment;
import '../test/master_data_table_view_hscrollbar_test.dart' as table;
import '../test/components/uten_editable_grid_hscrollbar_test.dart' as grid;
import '../test/components/uten_totals_summary_bar_test.dart' as totals;
import '../test/features/quality/quality_batch_approval_recovery_test.dart'
    as quality;
import '../test/features/warehouse/warehouse_task_scope_test.dart'
    as warehouse_scope;
import '../test/features/warehouse/production_finished_arrival_registration_page_test.dart'
    as arrival;
import '../test/features/warehouse/warehouse_task_record_actions_routing_test.dart'
    as count_route;
import '../test/features/production/pages/production_draw_request_page_test.dart'
    as draw;
import '../test/components/inputs/uten_year_and_master_filter_test.dart'
    as year;
import '../test/features/finance/finance_batch_entry_test.dart'
    as finance_entry;
import '../test/features/finance/supplier_settlement_panel_test.dart'
    as monthly;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('editor-runtime', editor.main);
  group('detail-runtime', detail.main);
  group('shipment-runtime', shipment.main);
  group('table-runtime', table.main);
  group('grid-runtime', grid.main);
  group('totals-runtime', totals.main);
  group('quality-runtime', quality.main);
  group('warehouse-scope-runtime', warehouse_scope.main);
  group('arrival-runtime', arrival.main);
  group('count-route-runtime', count_route.main);
  group('draw-runtime', draw.main);
  group('year-runtime', year.main);
  group('finance-entry-runtime', finance_entry.registerFinanceBatchEntryTests);
  group('monthly-runtime', monthly.main);
}
