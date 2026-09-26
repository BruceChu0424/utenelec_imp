package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import jakarta.servlet.http.HttpServletRequest;
import lombok.RequiredArgsConstructor;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.io.IOException;
import java.util.UUID;

/**
 * 组装信息导入（goods:bom:create，与「粘贴组件信息」同一权限口径）。
 *
 * <p>两段式「先检测后提交」（复用货品导入的有界上传与单槽并发口径）：
 * - POST /api/master/goods/{id}/bom/import/detect?mode= → 只读解析 + 逐行校验报告
 * - POST /api/master/goods/{id}/bom/import/commit?mode= → 重新解析复检后一个事务按层写入
 *
 * <p>格式 = 「导出组件」的 13 列；序号列的级联段（1 / 2 / 2.1）表达层级，
 * 导出改完可直接导回。mode：REPLACE（按文件为准，替换各级现有组件）/
 * APPEND（在现有组件后追加）。
 */
@RestController
@RequestMapping("/api/master/goods")
@RequiredArgsConstructor
public class GoodsBomImportController {

    /** 与货品导入同一上限（10 MiB，取工作簿安全检查的压缩包上限）。 */
    private static final long MAX_BYTES = GoodsImportWorkbookSecurity.MAX_COMPRESSED_BYTES;

    private final GoodsBomImportService service;

    /** 单 JVM 导入槽：POI 解析要整本工作表进内存，多来源并发会放大内存峰值。 */
    private final java.util.concurrent.Semaphore importSlot =
            new java.util.concurrent.Semaphore(1, true);

    @PostMapping("/{id}/bom/import/detect")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomImportReport detect(@PathVariable UUID id, HttpServletRequest request)
            throws IOException {
        return withImportSlot(() -> service.detect(id, read(request)));
    }

    @PostMapping("/{id}/bom/import/commit")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomImportResult commit(@PathVariable UUID id,
                                  @RequestParam(defaultValue = "REPLACE") String mode,
                                  HttpServletRequest request)
            throws IOException {
        BomPasteRequest.Mode parsedMode;
        try {
            parsedMode = BomPasteRequest.Mode.valueOf(mode.toUpperCase());
        } catch (IllegalArgumentException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "mode 必须为 REPLACE 或 APPEND");
        }
        BomPasteRequest.Mode finalMode = parsedMode;
        return withImportSlot(() -> service.commit(id, read(request), finalMode));
    }

    private byte[] read(HttpServletRequest request) throws IOException {
        return GoodsImportController.readBounded(
                request.getInputStream(),
                request.getContentLengthLong(),
                MAX_BYTES,
                java.nio.file.Path.of(System.getProperty("java.io.tmpdir")));
    }

    private <T> T withImportSlot(IOExceptionOperation<T> operation) throws IOException {
        if (!importSlot.tryAcquire()) {
            throw new ApiException(ErrorCode.RATE_LIMITED, "当前已有导入任务，请稍后重试");
        }
        try {
            return operation.run();
        } finally {
            importSlot.release();
        }
    }

    @FunctionalInterface
    private interface IOExceptionOperation<T> {
        T run() throws IOException;
    }
}
