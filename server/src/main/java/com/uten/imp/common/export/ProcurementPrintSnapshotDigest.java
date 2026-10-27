package com.uten.imp.common.export;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;

/** Hash only immutable record components, including the procurement domain. */
final class ProcurementPrintSnapshotDigest {
    private static final ObjectWriter WRITER = new ObjectMapper().registerModule(new JavaTimeModule())
            .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS)
            .enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writer();
    private ProcurementPrintSnapshotDigest() { }
    static String of(ProcurementOrderPrintDocument document) {
        try {
            var digest = MessageDigest.getInstance("SHA-256");
            digest.update("procurement-print-snapshot-v2\n".getBytes(StandardCharsets.UTF_8));
            Map<String,Object> fields = new TreeMap<>();
            for (var component : ProcurementOrderPrintDocument.class.getRecordComponents())
                fields.put(component.getName(), component.getAccessor().invoke(document));
            try (var output = new DigestOutputStream(OutputStream.nullOutputStream(), digest)) {
                WRITER.writeValue(output, fields);
            }
            return HexFormat.of().formatHex(digest.digest());
        } catch (ReflectiveOperationException | IOException | NoSuchAlgorithmException failure) {
            throw new IllegalStateException("订货单打印快照校验失败", failure);
        }
    }
}
