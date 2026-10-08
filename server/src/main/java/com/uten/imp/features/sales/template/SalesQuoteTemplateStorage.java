package com.uten.imp.features.sales.template;

import com.uten.imp.common.storage.ImmutableDocumentStore;
import org.springframework.stereotype.Component;

/** Template files share immutable storage, malware scanning and rollback cleanup. */
@Component
public class SalesQuoteTemplateStorage {
    static final int MAX_BYTES = 15 * 1024 * 1024;
    private static final String MIME = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
    private final ImmutableDocumentStore documents;

    public SalesQuoteTemplateStorage(ImmutableDocumentStore documents) {
        this.documents = documents;
    }

    public record ObjectRef(String provider, String key, String version, long size, String sha256) { }

    public ObjectRef save(byte[] bytes) {
        var object = documents.save("SALES_QUOTE_TEMPLATE", "template.xlsx", MIME, bytes);
        return new ObjectRef(object.provider(), object.key(), object.version(), object.size(), object.sha256());
    }

    public byte[] read(ObjectRef object) {
        if (object == null) throw new IllegalArgumentException("报价模板文件不存在");
        return documents.read(new ImmutableDocumentStore.Reference(object.provider(), object.key(), object.version(), object.size(), object.sha256()));
    }

    public byte[] readLegacy(byte[] bytes) {
        return documents.checkLegacy("SALES_QUOTE_TEMPLATE_LEGACY", bytes);
    }

    static String digest(byte[] bytes) { return ImmutableDocumentStore.digest(bytes); }
}
