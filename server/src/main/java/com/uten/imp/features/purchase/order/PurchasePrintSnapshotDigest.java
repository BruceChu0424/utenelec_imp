package com.uten.imp.features.purchase.order;

import com.fasterxml.jackson.databind.*;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.*;
import java.util.*;

/** Same immutable supplier-facing snapshot, independent of serializer defaults or a request timestamp. */
final class PurchasePrintSnapshotDigest {
    private static final ObjectWriter WRITER=new ObjectMapper().registerModule(new JavaTimeModule())
            .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS).enable(SerializationFeature.ORDER_MAP_ENTRIES_BY_KEYS).writer();
    private PurchasePrintSnapshotDigest() { }
    static String of(PurchaseOrderPrintService.PrintDocument document) {
        try {
            var digest=MessageDigest.getInstance("SHA-256");
            digest.update("purchase-print-snapshot-v1\n".getBytes(StandardCharsets.UTF_8));
            // Record components exclude the derived JSON digest getter and contain only original fields.
            Map<String,Object> fields=new TreeMap<>();
            for(var component:PurchaseOrderPrintService.PrintDocument.class.getRecordComponents())
                fields.put(component.getName(),component.getAccessor().invoke(document));
            try(var output=new DigestOutputStream(OutputStream.nullOutputStream(),digest)){WRITER.writeValue(output,fields);}
            return HexFormat.of().formatHex(digest.digest());
        }catch(ReflectiveOperationException|IOException|NoSuchAlgorithmException failure){throw new IllegalStateException("采购打印快照校验失败",failure);}
    }
}
