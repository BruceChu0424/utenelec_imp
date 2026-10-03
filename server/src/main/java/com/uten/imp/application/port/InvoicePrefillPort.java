package com.uten.imp.application.port;

import java.util.List;
import java.util.Map;

/** Local-only invoice extraction. Suggestions never create an expense, invoice or attachment. */
public interface InvoicePrefillPort {
    Map<String, Object> fromText(List<String> lines);
    Map<String, Object> fromImage(byte[] bytes, String mediaType);
}
