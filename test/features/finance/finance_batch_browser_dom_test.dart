import '../../support/finance_dropdown_dom_stub.dart'
    if (dart.library.js_interop) '../../support/finance_dropdown_dom_web.dart'
    as dropdown_dom;
import 'finance_batch_entry_test.dart' show registerFinanceBatchEntryTests;

// Same original body/assertions, with its real DOM engine in a separate suite.
void main() {
  dropdown_dom.initializeFinanceDropdownDom();
  registerFinanceBatchEntryTests(browserDomOnly: true);
}
