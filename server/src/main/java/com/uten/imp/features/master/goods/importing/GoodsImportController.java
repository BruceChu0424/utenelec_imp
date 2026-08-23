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
import java.util.UUID;
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

    @PostMapping("/detect")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportReport detect(HttpServletRequest request) throws IOException {
        return withImportSlot(() -> service.detect(read(request)));
    }

    @PostMapping("/commit")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportResult commit(@RequestParam UUID planId,
                                    @RequestParam(required = false) String filename,
                                    HttpServletRequest request) throws IOException {
        return withImportSlot(() -> service.commit(planId, read(request), filename));
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
