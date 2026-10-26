package com.uten.imp.features.master.goods.costing;

import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.BoundedDocumentExportService;
import com.uten.imp.common.export.LegacyExportBudget;
import com.uten.imp.common.export.TableColumnProjection;
import com.uten.imp.common.web.DownloadContentDisposition;
import com.uten.imp.security.SecurityContextCurrentUser;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import lombok.RequiredArgsConstructor;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RestController;
import java.time.LocalDate;
import java.util.UUID;

@RestController
@RequiredArgsConstructor
public class GoodsActualCostExportController {
    private final GoodsActualCostSnapshotService snapshots;
    private final BoundedDocumentExportService downloads;
    private final SecurityContextCurrentUser current;
    private final AuditService audit;
    public record Request(@NotNull UUID goodsId, UUID executionSegmentId, LocalDate from, LocalDate to, UUID revisionId,
            @NotNull @Pattern(regexp="[0-9a-f]{64}") String expectedDigest,
            @Pattern(regexp="xlsx|pdf") String format, @Size(max=128) String password,
            @Valid TableColumnProjection columnProjection) {}

    @PostMapping("/api/master/goods/cost-sheets/actual/export")
    @PreAuthorize("hasAuthority('goods:view') and hasAuthority('goods:cost:view') and hasAuthority('goods:cost:export')")
    public ResponseEntity<byte[]> export(@Valid @RequestBody Request request) {
        String key = request.columnProjection() == null ? "" : request.columnProjection().tableKey();
        String section = key != null && key.endsWith(".1") ? "产出与撤回"
                : key != null && key.endsWith(".2") ? "成本对象" : "物料及费用来源";
        boolean asPdf = "pdf".equals(request.format());
        byte[] bytes=downloads.build(asPdf?"pdf":"xlsx",request.password(),request.columnProjection(),section,"view_goods_cost",
                ()->snapshots.streamExport(new GoodsActualCostQueryPort.Query(request.goodsId(),request.executionSegmentId(),
                        request.from(),request.to(),request.revisionId()),request.expectedDigest(),LegacyExportBudget.MAX_ROWS));
        current.get().ifPresent(user -> audit.logExplicit(user.getId(), user.getLoginAccount(), "export_goods_actual_cost",
                "master_data", request.goodsId() + ":" + request.expectedDigest() + ":" + (asPdf ? "pdf" : "xlsx"), "success"));
        return ResponseEntity.ok().header("Content-Disposition", DownloadContentDisposition.attachment(
                "actual-cost-" + request.goodsId() + "." + (asPdf ? "pdf" : "xlsx")))
                .header("Content-Type", asPdf ? "application/pdf" : "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
                .header("X-Cost-Digest", request.expectedDigest()).body(bytes);
    }
}
