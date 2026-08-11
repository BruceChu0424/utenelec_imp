package com.uten.imp.features.master.goods.importing;

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
import java.util.UUID;

/**
 * 货品批量导入 API（goods:import）。
 *
 * <p>上传走原始字节流（{@code HttpServletRequest.getInputStream()}，Content-Type: application/octet-stream），
 * 与附件直传同模式，不经 multipart；前端 file_picker 取 bytes 后 POST 即可。
 *
 * <ul>
 *   <li>POST /import/detect → 解析+校验，返回报告（不写库）。</li>
 *   <li>POST /import/commit?filename= → 原子事务导入，返回批次结果（含 batchId 供撤回）。</li>
 *   <li>GET  /import/latest → 最近未撤回批次摘要（撤回按钮入口）。</li>
 *   <li>DEL  /import/{batchId} → 撤回该批次（软删本批新建实体）。</li>
 * </ul>
 */
@RestController
@RequestMapping("/api/master/goods/import")
@RequiredArgsConstructor
public class GoodsImportController {

    /** 导入文件大小硬上限（50MB，防 OOM）。 */
    private static final long MAX_BYTES = 50L * 1024 * 1024;

    private final GoodsImportService service;

    @PostMapping("/detect")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportReport detect(HttpServletRequest request) throws IOException {
        return service.detect(read(request));
    }

    @PostMapping("/commit")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportResult commit(@RequestParam(required = false) String filename,
                                    HttpServletRequest request) throws IOException {
        return service.commit(read(request), filename);
    }

    @GetMapping("/latest")
    @PreAuthorize("hasAuthority('goods:import')")
    public GoodsImportBatchInfo latest() {
        return service.latestBatch();
    }

    @DeleteMapping("/{batchId}")
    @PreAuthorize("hasAuthority('goods:import')")
    public int undo(@PathVariable UUID batchId) {
        return service.undo(batchId);
    }

    private byte[] read(HttpServletRequest request) throws IOException {
        long len = request.getContentLengthLong();
        if (len > MAX_BYTES) {
            throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                    "导入文件过大（>50MB），请拆分后重试");
        }
        byte[] bytes = request.getInputStream().readAllBytes();
        if (bytes.length > MAX_BYTES) {
            throw new com.uten.imp.common.web.ApiException(
                    com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,
                    "导入文件过大（>50MB），请拆分后重试");
        }
        return bytes;
    }
}
