package com.uten.imp.common.files.document;

import java.text.Normalizer;
import java.util.List;
import java.util.regex.Pattern;

/** A single prefill must not collapse several invoices into one set of totals. Conservative by design. */
public final class InvoiceMultiplicity {
    private InvoiceMultiplicity() {}
    // A normal Chinese invoice repeats its total in words; that is not a second invoice.
    private static final Pattern TOTAL = Pattern.compile("价\\s*税\\s*合\\s*计(?!\\s*\\(\\s*大\\s*写\\s*\\))|grand\\s+total", Pattern.CASE_INSENSITIVE);
    private static final Pattern NUMBER = Pattern.compile("发\\s*票\\s*号\\s*码|invoice\\s*(?:no\\.?|number|#)", Pattern.CASE_INSENSITIVE);
    public static boolean multiple(List<String> lines) {
        String text = Normalizer.normalize(String.join("\n", lines), Normalizer.Form.NFKC);
        return TOTAL.matcher(text).results().limit(2).count() > 1 || NUMBER.matcher(text).results().limit(2).count() > 1;
    }
}
