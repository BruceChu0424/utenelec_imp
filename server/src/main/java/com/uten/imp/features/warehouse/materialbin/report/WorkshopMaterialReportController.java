package com.uten.imp.features.warehouse.materialbin.report;

import com.uten.imp.common.web.PageResponse;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.BinUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.LedgerRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.MissingWeightRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.ProductUsageRow;
import com.uten.imp.features.warehouse.materialbin.report.WorkshopMaterialReportDtos.WastePoint;
import org.springframework.format.annotation.DateTimeFormat;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

/**
 * 车间内料仓用量报表 (ADR-131 §5.10): 用量、产品用料、耗用差异率趋势、缺单重清单返回行的列表, 收发明细分页。
 * 金额列只给持"查看货品成本"权限的人, 其余人收到空值。
 */
@RestController
@RequestMapping("/api/workshop-material/reports")
public class WorkshopMaterialReportController {

    private final WorkshopMaterialReportQueryService reports;

    public WorkshopMaterialReportController(WorkshopMaterialReportQueryService reports) {
        this.reports = reports;
    }

    @GetMapping("/bin-usage")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<BinUsageRow> binUsage(@RequestParam UUID binId,
                                      @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                      @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reports.binUsage(binId, from, to);
    }

    @GetMapping("/product-usage")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<ProductUsageRow> productUsage(@RequestParam UUID binId,
                                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                              @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to) {
        return reports.productUsage(binId, from, to);
    }

    @GetMapping("/waste-trend")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<WastePoint> wasteTrend(@RequestParam UUID binId, @RequestParam(required = false) UUID goodsId) {
        return reports.wasteTrend(binId, goodsId);
    }

    @GetMapping("/missing-weights")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<MissingWeightRow> missingWeights(@RequestParam UUID binId) {
        return reports.missingWeights(binId);
    }

    @GetMapping("/ledger")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public PageResponse<LedgerRow> ledger(@RequestParam UUID binId,
                                          @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate from,
                                          @RequestParam(required = false) @DateTimeFormat(iso = DateTimeFormat.ISO.DATE) LocalDate to,
                                          @RequestParam(defaultValue = "1") int page,
                                          @RequestParam(defaultValue = "50") int size) {
        return reports.ledger(binId, from, to, page, size);
    }
}
