// One profile bundle for isolated real-UI verification; every business source
// is synthetic. Only the stream view uses the loopback fixture HTTP endpoints.
import 'b1_report_export_harness.dart' as reports;
import 'b1_batch_shipping_harness.dart' as shipping;
import 'b1_party_read_harness.dart' as parties;
import 'b1_stream_download_harness.dart' as streams;
import 'b1_master_inline_harness.dart' as masters;
import 'b1_native_facet_harness.dart' as native;

Future<void> main() async {
  switch (Uri.base.queryParameters['view']) {
    case 'shipping':
      await Future.sync(shipping.main);
    case 'parties':
      await Future.sync(parties.main);
    case 'stream':
      await Future.sync(streams.main);
    case 'masters':
      await Future.sync(masters.main);
    case 'native':
      await Future.sync(native.main);
    default:
      await Future.sync(reports.main);
  }
}
