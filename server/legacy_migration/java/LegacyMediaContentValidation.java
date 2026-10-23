package com.uten.imp.features.attachment;

import java.io.InputStream;
import com.uten.imp.common.storage.StorageService;
import com.uten.imp.common.storage.StorageProviderRegistry;
import com.uten.imp.config.props.StorageProperties;
import java.security.MessageDigest;
import java.util.HexFormat;

/** Offline bridge to the same content/dimension guard used by attachment confirm. */
public final class LegacyMediaContentValidation {
    private LegacyMediaContentValidation() {}

    public static String inspect(InputStream input, long size, String name, String type) {
        return AttachmentContentInspector.inspect(input, size, name, type).sha256();
    }

    public static void verifyDownload(StorageService storage, StorageProperties properties,
                                      String key, String hash, long size) throws Exception {
        var metadata = new Attachment();
        metadata.setStorageProvider("local"); metadata.setStorageKey(key);
        metadata.setStorageVersion(null); metadata.setSizeBytes(size); metadata.setSha256(hash);
        metadata.setStoredSizeBytes(size); metadata.setStorageEncoding("IDENTITY");
        var verifier = new AttachmentDownloadVerifier(new StorageProviderRegistry(storage, properties), properties);
        var digest = MessageDigest.getInstance("SHA-256"); long count = 0;
        try (var input = verifier.open(metadata)) {
            byte[] buffer = new byte[65536]; int read;
            while ((read = input.read(buffer)) != -1) { count += read; digest.update(buffer,0,read); }
        }
        if (count != size || !hash.equals(HexFormat.of().formatHex(digest.digest())))
            throw new IllegalStateException("Application download verifier digest differs");
    }
}
