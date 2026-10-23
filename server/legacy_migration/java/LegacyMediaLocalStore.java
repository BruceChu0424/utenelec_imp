package com.uten.imp.common.storage;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.config.props.StorageProperties;
import com.uten.imp.features.attachment.LegacyMediaContentValidation;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Instant;
import java.util.ArrayList;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.Map;
import java.security.MessageDigest;

/** Database-free preparation through the production local storage adapter. */
public final class LegacyMediaLocalStore {
    public static void main(String[] args) throws Exception {
        if (args.length != 3) throw new IllegalArgumentException("plan.json storage-root receipt.json");
        var mapper = new ObjectMapper();
        var plan = mapper.readTree(Path.of(args[0]).toFile());
        var properties = new StorageProperties();
        properties.setProvider("local");
        properties.setLocalDir(Path.of(args[1]).toAbsolutePath().normalize().toString());
        var storage = new LocalDiskStorageService(properties);
        storage.init();
        var results = new ArrayList<Map<String,Object>>();
        for (var file : plan.withArray("files")) {
            String key = file.required("storage_key").asText();
            String expected = file.required("sha256").asText();
            long size = file.required("bytes").asLong();
            Path source = Path.of(file.required("source_path").asText());
            String inspected = LegacyMediaContentValidation.inspect(Files.newInputStream(source), size,
                    file.required("original_name").asText(), "image/jpeg");
            if (!expected.equals(inspected)) throw new IllegalStateException("Source digest differs");
            var finalBefore = storage.inspectObject(StorageService.ObjectLocation.FINAL, key);
            if (!finalBefore.exists()) {
                var stage = storage.describe(key);
                if (!stage.exists()) {
                    try (var input = Files.newInputStream(source)) { storage.store(key, input, size); }
                    stage = storage.describe(key);
                }
                requireHash(storage.openForValidation(key, null), expected, size);
                storage.promoteToFinal(key, stage);
            }
            var actual = storage.inspectObject(StorageService.ObjectLocation.FINAL, key);
            requireHash(storage.openFinal(key, null), expected, size);
            if (actual.versionId() != null || actual.size() != size || actual.storedSize() != size
                    || !"IDENTITY".equals(actual.encoding())) throw new IllegalStateException("Local identity differs");
            LegacyMediaContentValidation.verifyDownload(storage, properties, key, expected, size);
            // Only the staged copy created for this exact import key is removed.
            if (storage.describe(key).exists()) {
                requireHash(storage.openForValidation(key, null), expected, size);
                storage.deleteStaging(key, null);
            }
            var row = new LinkedHashMap<String,Object>();
            row.put("attachment_id", file.required("attachment_id").asText());
            row.put("storage_key", key); row.put("sha256", expected);
            row.put("bytes", size); row.put("stored_size_bytes", actual.storedSize());
            row.put("storage_encoding", actual.encoding()); row.put("storage_provider", "local");
            row.put("storage_version", null); row.put("storage_etag", null);
            row.put("application_download_verifier", "PASS");
            row.put("promoted_at", Instant.now().toString()); results.add(row);
        }
        var receipt = new LinkedHashMap<String,Object>();
        receipt.put("adapter", LocalDiskStorageService.class.getName());
        receipt.put("root", properties.getLocalDir()); receipt.put("files", results);
        mapper.writerWithDefaultPrettyPrinter().writeValue(Path.of(args[2]).toFile(), receipt);
    }

    private static void requireHash(java.io.InputStream input, String expected, long size) throws Exception {
        var digest = MessageDigest.getInstance("SHA-256"); long total = 0;
        try (input) {
            byte[] buffer = new byte[65536]; int count;
            while ((count = input.read(buffer)) != -1) { total += count; digest.update(buffer,0,count); }
        }
        if (total != size || !HexFormat.of().formatHex(digest.digest()).equals(expected))
            throw new IllegalStateException("Stored object digest differs; no object is replaced");
    }
}
