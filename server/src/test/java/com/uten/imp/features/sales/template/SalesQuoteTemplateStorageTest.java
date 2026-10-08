package com.uten.imp.features.sales.template;

import com.uten.imp.common.storage.LocalDiskStorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.config.props.StorageProperties;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import java.nio.file.Files;
import java.nio.file.Path;
import static org.assertj.core.api.Assertions.*;

class SalesQuoteTemplateStorageTest {
    @TempDir Path root;
    @Test void exactStoredBytesAreCheckedAndRollbackCleansBothNamespaces() throws Exception {
        var properties = new StorageProperties(); properties.setLocalDir(root.toString());
        var local = new LocalDiskStorageService(properties); ReflectionTestUtils.invokeMethod(local, "init");
        var storage = new SalesQuoteTemplateStorage(new com.uten.imp.common.storage.ImmutableDocumentStore(local, new StorageProviderRegistry(local, properties), com.uten.imp.common.files.malware.DocumentSafetyTestSupport.scanning()));
        byte[] bytes = QuoteTemplateWorkbook.defaultTemplate().xlsx();
        TransactionSynchronizationManager.initSynchronization();
        try {
            var reference = storage.save(bytes);
            assertThat(reference.provider()).isEqualTo("local");
            assertThat(storage.read(reference)).isEqualTo(bytes);
            byte[] corrupt = bytes.clone(); corrupt[10] ^= 1;
            Files.write(root.resolve("final").resolve(reference.key()), corrupt);
            assertThatThrownBy(() -> storage.read(reference)).hasMessageContaining("校验失败");
            for (var callback : TransactionSynchronizationManager.getSynchronizations()) callback.afterCompletion(TransactionSynchronization.STATUS_ROLLED_BACK);
            assertThat(root.resolve("final").resolve(reference.key())).doesNotExist();
            assertThat(root.resolve("staging").resolve(reference.key())).doesNotExist();
        } finally { TransactionSynchronizationManager.clearSynchronization(); }
    }
}
