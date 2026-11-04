// Run with `dart compile js ...` and Node to exercise the actual JavaScript
// numeric backend independently of browser renderer startup.
import 'package:uten_imp/core/utils/rmb_amount.dart';

void main() {
  const cases = {
    '99999999999999.99': '人民币玖拾玖万亿玖仟玖佰玖拾玖亿玖仟玖佰玖拾玖万玖仟玖佰玖拾玖元玖角玖分',
    '90071992547409.91': '人民币玖拾万亿零柒佰壹拾玖亿玖仟贰佰伍拾肆万柒仟肆佰零玖元玖角壹分',
    '0.01': '人民币壹分',
    '0': '人民币零元整',
    '10001.05': '人民币壹万零壹元零伍分',
    '1e3': '',
    '1.005': '',
    '-1': '',
  };
  for (final entry in cases.entries) {
    if (rmbCapitalExact(entry.key) != entry.value) {
      throw StateError('Exact RMB JavaScript case failed for ${entry.key}');
    }
  }
  // ignore: avoid_print -- Standalone JavaScript smoke-test result for CI logs.
  print('JavaScript exact RMB checks passed: ${cases.length}');
}
