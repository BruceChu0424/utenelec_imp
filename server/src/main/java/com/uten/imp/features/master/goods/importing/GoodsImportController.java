package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.Map;
import java.util.UUID;
import java.util.Set;
import java.util.concurrent.Semaphore;

/**
 * 商品批量导入 API（权限：goods:import）。
 *
 * <p>上传使用 {@code application/octet-stream} 原始字节流，不经过 multipart。
 * 检测只解析和校验；提交在服务层事务中写入；最近批次可查询和撤回。</p>
 */
@RestController
@RequestMapping("/api/master/goods/import")
@RequiredArgsConstructor
public class GoodsImportController {

    /** 导入文件硬上限：10 MiB；OOXML 展开预算由服务层再次校验。 */
    private static final long MAX_BYTES = GoodsImportWorkbookSecurity.MAX_COMPRESSED_BYTES;

    private final GoodsImportService service;
    /**
     * Apache POI still needs an in-memory workbook after the bounded upload is
     * staged. Keep one JVM-wide controller slot on this single-node service so
     * many source IPs cannot multiply the 50 MiB + workbook memory peak.
     */
    private final Semaphore importSlot = new Semaphore(1, true);

    @PostMapping(value = "/detect", consumes = "!application/json")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportReport detect(@RequestParam(required = false) String mode,
                                    HttpServletRequest request) throws IOException {
        GoodsImportMode parsed = GoodsImportMode.parse(mode);
        return withImportSlot(() -> service.detect(read(request), Map.of(), Set.of(), Map.of(), parsed));
    }

    @PostMapping(value = "/detect", consumes = "application/json")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportReport detectJson(HttpServletRequest request) throws IOException {
        return withImportSlot(() -> {
            GoodsImportDetectRequest selection = readJson(request, GoodsImportDetectRequest.class);
            if (selection == null || selection.file() == null || selection.file().length == 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入检测缺少文件，请重新选择");
            }
            if (selection.file().length > MAX_BYTES) throw tooLarge();
            GoodsImportMode mode = GoodsImportMode.parse(selection.mode());
            if (!empty(selection.cellCorrections())) {
                return service.detect(selection.file(), selection.codeCorrections(), selection.excludedRowNums(),
                        selection.cellCorrections(), mode);
            }
            return empty(selection.codeCorrections()) && empty(selection.excludedRowNums())
                    ? service.detect(selection.file(), Map.of(), Set.of(), Map.of(), mode)
                    : service.detect(selection.file(), selection.codeCorrections(), selection.excludedRowNums(),
                            Map.of(), mode);
        });
    }

    @PostMapping(value = "/commit", consumes = "!application/json")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportResult commit(@RequestParam UUID planId,
                                    @RequestParam(required = false) String filename,
                                    @RequestParam(required = false) String mode,
                                    HttpServletRequest request) throws IOException {
        GoodsImportMode parsed = GoodsImportMode.parse(mode);
        return withImportSlot(() -> service.commit(planId, read(request), filename, Set.of(),
                Map.of(), Set.of(), Map.of(), parsed));
    }

    /** A separate mapping condition preserves the existing Java/controller contract. */
    @PostMapping(value = "/commit", params = "replaceRowKeys", consumes = "!application/json")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportResult commitReviewed(@RequestParam UUID planId,
                                            @RequestParam(required = false) String filename,
                                            @RequestParam Set<String> replaceRowKeys,
                                            @RequestParam(required = false) String mode,
                                            HttpServletRequest request) throws IOException {
        GoodsImportMode parsed = GoodsImportMode.parse(mode);
        return withImportSlot(() -> service.commit(planId, read(request), filename, replaceRowKeys,
                Map.of(), Set.of(), Map.of(), parsed));
    }

    @PostMapping(value = "/commit", consumes = "application/json")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportResult commitJson(HttpServletRequest request) throws IOException {
        return withImportSlot(() -> {
            GoodsImportCommitRequest selection = readJson(request, GoodsImportCommitRequest.class);
            if (selection == null || selection.file() == null || selection.file().length == 0
                    || selection.planId() == null) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入提交缺少文件或检测计划");
            }
            if (selection.file().length > MAX_BYTES) throw tooLarge();
            if (selection.replaceRowKeys() != null && (selection.replaceRowKeys().size() > 2000
                    || selection.replaceRowKeys().stream().anyMatch(key -> key == null || key.length() > 100))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "替换选择无效或超过 2000 行，请拆分文件后重试");
            }
            Set<String> keys = selection.replaceRowKeys() == null
                    ? Set.of() : Set.copyOf(selection.replaceRowKeys());
            GoodsImportMode mode = GoodsImportMode.parse(selection.mode());
            if (!empty(selection.cellCorrections())) {
                return service.commit(selection.planId(), selection.file(), selection.filename(), keys,
                        selection.codeCorrections(), selection.excludedRowNums(), selection.cellCorrections(), mode);
            }
            return empty(selection.codeCorrections()) && empty(selection.excludedRowNums())
                    ? service.commit(selection.planId(), selection.file(), selection.filename(), keys,
                            Map.of(), Set.of(), Map.of(), mode)
                    : service.commit(selection.planId(), selection.file(), selection.filename(), keys,
                            selection.codeCorrections(), selection.excludedRowNums(), Map.of(), mode);
        });
    }

    private <T> T readJson(HttpServletRequest request, Class<T> type) throws IOException {
        // Bound both encoded JSON and decoded workbook before the POI parser.
        byte[] body = readBounded(request.getInputStream(), request.getContentLengthLong(),
                15L * 1024 * 1024, Path.of(System.getProperty("java.io.tmpdir")));
        try {
            var mapper = new com.fasterxml.jackson.databind.ObjectMapper()
                    .enable(com.fasterxml.jackson.core.JsonParser.Feature.STRICT_DUPLICATE_DETECTION)
                    .enable(com.fasterxml.jackson.databind.DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
            var payload = mapper.readTree(body);
            if (payload == null) return null;
            validateWireRows(payload);
            return mapper.treeToValue(payload, type);
        } catch (com.fasterxml.jackson.core.JsonProcessingException malformed) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入内容无效，请重新检测文件");
        }
    }

    private static boolean empty(java.util.Map<?, ?> values) { return values == null || values.isEmpty(); }
    private static boolean empty(java.util.Set<?> values) { return values == null || values.isEmpty(); }

    private static void validateWireRows(com.fasterxml.jackson.databind.JsonNode payload) {
        var corrections = payload.get("codeCorrections");
        if (corrections != null && !corrections.isNull()) {
            if (!corrections.isObject()) throw invalidRowSelection();
            var names = corrections.fieldNames();
            while (names.hasNext()) {
                validateRowKey(names.next());
            }
        }
        var cells = payload.get("cellCorrections");
        if (cells != null && !cells.isNull()) {
            if (!cells.isObject()) throw invalidRowSelection();
            var entries = cells.properties().iterator();
            while (entries.hasNext()) {
                var row = entries.next();
                validateRowKey(row.getKey());
                if (!row.getValue().isObject()) throw invalidRowSelection();
                for (var value : row.getValue()) {
                    // Do not let Jackson silently coerce a number, boolean or
                    // null into a different correction than the employee saw.
                    if (!value.isTextual()) throw invalidRowSelection();
                }
            }
        }
        var excluded = payload.get("excludedRowNums");
        if (excluded != null && !excluded.isNull()) {
            if (!excluded.isArray()) throw invalidRowSelection();
            var rows = new java.util.HashSet<Integer>();
            for (var row : excluded) {
                if (!row.isIntegralNumber() || !row.canConvertToInt() || !rows.add(row.intValue())) {
                    throw invalidRowSelection();
                }
            }
        }
    }

    private static void validateRowKey(String key) {
        // Reject aliases such as "02" before converting to Integer keys;
        // otherwise Jackson can silently overwrite the same logical row.
        if (!key.matches("[1-9][0-9]*")) throw invalidRowSelection();
        try {
            Integer.parseInt(key);
        } catch (NumberFormatException invalid) {
            throw invalidRowSelection();
        }
    }

    private static ApiException invalidRowSelection() {
        return new ApiException(ErrorCode.VALIDATION_FAILED, "导入行号选择无效，请重新检测文件");
    }

    @GetMapping("/latest")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportBatchInfo latest() {
        return service.latestBatch();
    }

    @DeleteMapping("/{batchId}")
    @PreAuthorize("hasAuthority('goods:import:undo')")
    public int undo(@PathVariable UUID batchId) {
        return service.undo(batchId);
    }

    private byte[] read(HttpServletRequest request) throws IOException {
        return readBounded(
                request.getInputStream(),
                request.getContentLengthLong(),
                MAX_BYTES,
                Path.of(System.getProperty("java.io.tmpdir")));
    }

    private <T> T withImportSlot(ImportOperation<T> operation) throws IOException {
        if (!importSlot.tryAcquire()) {
            throw new ApiException(
                    ErrorCode.RATE_LIMITED,
                    "当前已有商品导入任务，请稍后重试");
        }
        try {
            return operation.run();
        } finally {
            importSlot.release();
        }
    }

    @FunctionalInterface
    private interface ImportOperation<T> {
        T run() throws IOException;
    }

    /**
     * Stages an upload with a hard streaming limit before allocating the byte
     * array required by the existing workbook parser. The temporary file is
     * removed on success, validation failure and I/O failure.
     */
    static byte[] readBounded(InputStream input,
                              long declaredLength,
                              long maxBytes,
                              Path tempDirectory) throws IOException {
        if (maxBytes < 0 || maxBytes > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("maxBytes must fit in a Java byte array");
        }
        if (declaredLength > maxBytes) {
            throw tooLarge();
        }

        Path staged = Files.createTempFile(tempDirectory, "uten-goods-import-", ".part");
        Throwable failure = null;
        try {
            long total = 0;
            byte[] buffer = new byte[64 * 1024];
            try (OutputStream output = Files.newOutputStream(
                    staged,
                    StandardOpenOption.WRITE,
                    StandardOpenOption.TRUNCATE_EXISTING)) {
                int count;
                while ((count = input.read(buffer)) != -1) {
                    if (count == 0) {
                        continue;
                    }
                    if (total > maxBytes - count) {
                        throw tooLarge();
                    }
                    output.write(buffer, 0, count);
                    total += count;
                }
            }

            byte[] bytes = new byte[(int) total];
            try (InputStream stagedInput = Files.newInputStream(staged)) {
                int offset = 0;
                while (offset < bytes.length) {
                    int count = stagedInput.read(bytes, offset, bytes.length - offset);
                    if (count < 0) {
                        throw new IOException("staged goods import ended unexpectedly");
                    }
                    offset += count;
                }
                if (stagedInput.read() != -1) {
                    throw new IOException("staged goods import changed while being read");
                }
            }
            return bytes;
        } catch (IOException | RuntimeException | Error error) {
            failure = error;
            throw error;
        } finally {
            try {
                Files.deleteIfExists(staged);
            } catch (IOException cleanupError) {
                if (failure != null) {
                    failure.addSuppressed(cleanupError);
                } else {
                    throw cleanupError;
                }
            }
        }
    }

    private static ApiException tooLarge() {
        return new ApiException(
                ErrorCode.PAYLOAD_TOO_LARGE,
                "导入文件超过 10 MiB，请拆分后重试");
    }
}
