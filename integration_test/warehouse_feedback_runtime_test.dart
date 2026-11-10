// Warehouse and quality widgets on the real engine, with separately named groups.
// Fixtures remain local; this runner never targets the company service.
import 'package:integration_test/integration_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/features/quality/quality_batch_approval_recovery_test.dart'
    as quality;
import '../test/features/warehouse/warehouse_task_scope_test.dart' as scope;
import '../test/features/warehouse/production_finished_arrival_registration_page_test.dart'
    as arrival;
import '../test/features/warehouse/warehouse_task_record_actions_routing_test.dart'
    as count;
import '../test/features/production/pages/production_draw_request_page_test.dart'
    as draw;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  group('quality-runtime', quality.main);
  group('scope-runtime', scope.main);
  group('arrival-runtime', arrival.main);
  group('count-runtime', count.main);
  group('draw-runtime', draw.main);
}
