package com.uten.imp.features.master.goods.importing;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.master.goods.dto.BomPasteRequest;
import com.uten.imp.features.master.goods.GoodsBomFileLimits;
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
 * <p>格式与「导出组件」一致；序号列的级联段（1 / 2 / 2.1）表达层级。
 * MERGE 合并核对保留文件外组件，空值补齐、非空差异按行确认；REPLACE 覆盖和 APPEND 追加保留旧合同。
 * JSON 提交在请求体中携带 base64 文件和替换行选择，避免大文件的选择列表超过 URL 长度上限。
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

    @PostMapping(value = "/{id}/bom/import/commit", consumes = "!application/json")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomImportResult commit(@PathVariable UUID id,
                                  @RequestParam(defaultValue = "REPLACE") String mode,
                                  @RequestParam(required = false) String stateFingerprint,
                                  @RequestParam(required = false) java.util.Set<String> replaceRowKeys,
                                  HttpServletRequest request)
            throws IOException {
        if ("MERGE".equalsIgnoreCase(mode)) {
            return withImportSlot(() -> service.commitMerged(id, read(request), stateFingerprint, replaceRowKeys));
        }
        if (replaceRowKeys != null && !replaceRowKeys.isEmpty()) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "逐行替换选择只适用于合并核对导入");
        }
        BomPasteRequest.Mode parsedMode;
        try {
            parsedMode = BomPasteRequest.Mode.valueOf(mode.toUpperCase());
        } catch (IllegalArgumentException e) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入方式只能是合并核对、覆盖或追加，请重新选择");
        }
        BomPasteRequest.Mode finalMode = parsedMode;
        return withImportSlot(() -> service.commit(id, read(request), finalMode, stateFingerprint));
    }

    @PostMapping(value = "/{id}/bom/import/commit", consumes = "application/json")
    @PreAuthorize("hasAuthority('goods:bom:create')")
    public BomImportResult commitJson(@PathVariable UUID id, HttpServletRequest request) throws IOException {
        return withImportSlot(() -> {
            byte[] body = GoodsImportController.readBounded(request.getInputStream(), request.getContentLengthLong(),
                    15L * 1024 * 1024, java.nio.file.Path.of(System.getProperty("java.io.tmpdir")));
            BomImportCommitRequest selection;
            try {
                selection = new com.fasterxml.jackson.databind.ObjectMapper().readValue(body, BomImportCommitRequest.class);
            } catch (com.fasterxml.jackson.core.JsonProcessingException malformed) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入提交内容无效，请重新检测文件");
            }
            if (selection == null || selection.file() == null || selection.file().length == 0) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "导入提交缺少文件，请重新检测");
            }
            if (selection.file().length > MAX_BYTES) {
                throw new ApiException(ErrorCode.PAYLOAD_TOO_LARGE, "导入文件超过 10 MiB，请拆分后重试");
            }
            if (selection.replaceRowKeys() != null && (selection.replaceRowKeys().size() > GoodsBomFileLimits.MAX_ROWS
                    || selection.replaceRowKeys().stream().anyMatch(key -> key == null || key.length() > 100))) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "替换选择无效或超过 2000 行，请拆分文件后重试");
            }
            if (selection.mode() != null && !"MERGE".equalsIgnoreCase(selection.mode())) {
                throw new ApiException(ErrorCode.VALIDATION_FAILED, "逐行核对提交仅支持合并导入");
            }
            return service.commitMerged(id, selection.file(), selection.stateFingerprint(), selection.replaceRowKeys());
        });
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
