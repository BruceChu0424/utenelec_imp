import 'package:integration_test/integration_test.dart';
import '../test/features/warehouse/inbound_arrival_registration_page_test.dart'
    as arrival;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  arrival.registerArrivalReceiverHttpCases();
}
