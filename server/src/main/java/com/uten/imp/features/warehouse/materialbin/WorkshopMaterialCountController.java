package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.common.web.ApiError;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CorrectCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountDetail;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineInput;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.CountLineView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.PeriodView;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.StartCountResult;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.VersionRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ZeroRestRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ZeroRestResult;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.PutMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.OffsetDateTime;
import java.util.List;
import java.util.UUID;

/** 内料仓期间与盘点 (ADR-131 §5.7)。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialCountController {

    /** 一行保存时的版本冲突: 统一错误体之外带回最新那一行, 页面直接回显。 */
    public record LineConflictBody(OffsetDateTime timestamp, int status, String code, String message,
                                   List<ApiError.FieldError> fieldErrors, CountLineView latest) {}

    private final WorkshopMaterialPeriodService periods;
    private final WorkshopMaterialCountService counts;

    public WorkshopMaterialCountController(WorkshopMaterialPeriodService periods, WorkshopMaterialCountService counts) {
        this.periods = periods;
        this.counts = counts;
    }

    @GetMapping("/periods")
    @PreAuthorize("hasAnyAuthority('workshop_material:view','workshop_material:count','stock:count:warehouse_review')")
    public PeriodList periods(@RequestParam UUID binId) {
        return periods.list(binId);
    }

    @GetMapping("/periods/{periodId}")
    @PreAuthorize("hasAnyAuthority('workshop_material:view','workshop_material:count','stock:count:warehouse_review')")
    public PeriodView period(@PathVariable UUID periodId) {
        return periods.detail(periodId);
    }

    @PostMapping("/periods/{periodId}/start-count")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public StartCountResult startCount(@PathVariable UUID periodId, @RequestBody StartCountRequest request) {
        return periods.startCount(periodId, request);
    }

    @PostMapping("/periods/{periodId}/withdraw-count")
    @PreAuthorize("hasAnyAuthority('workshop_material:count','stock:count:warehouse_review')")
    public PeriodView withdrawCount(@PathVariable UUID periodId, @RequestBody VersionRequest request) {
        return periods.withdrawCount(periodId, request);
    }

    @PostMapping("/periods/{periodId}/correct-count")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public CountDetail correctCount(@PathVariable UUID periodId, @RequestBody CorrectCountRequest request) {
        return counts.correct(periodId, request);
    }

    @GetMapping("/counts/{countId}")
    @PreAuthorize("hasAnyAuthority('workshop_material:view','workshop_material:count','stock:count:warehouse_review')")
    public CountDetail count(@PathVariable UUID countId) {
        return counts.detail(countId);
    }

    @PutMapping("/counts/{countId}/lines/{clientLineKey}")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public ResponseEntity<?> saveLine(@PathVariable UUID countId, @PathVariable String clientLineKey,
                                      @RequestBody CountLineInput request) {
        try {
            return ResponseEntity.ok(counts.saveLine(countId, clientLineKey, request));
        } catch (WorkshopMaterialCountService.LineConflict conflict) {
            return conflict(conflict);
        }
    }

    @DeleteMapping("/counts/{countId}/lines/{clientLineKey}")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public ResponseEntity<?> deleteLine(@PathVariable UUID countId, @PathVariable String clientLineKey,
                                        @RequestParam(required = false) Long expectedVersion) {
        try {
            counts.deleteLine(countId, clientLineKey, expectedVersion);
            return ResponseEntity.noContent().build();
        } catch (WorkshopMaterialCountService.LineConflict conflict) {
            return conflict(conflict);
        }
    }

    @PostMapping("/counts/{countId}/zero-rest")
    @PreAuthorize("hasAuthority('workshop_material:count')")
    public ZeroRestResult zeroRest(@PathVariable UUID countId, @RequestBody ZeroRestRequest request) {
        return counts.zeroRest(countId, request);
    }

    @PostMapping("/counts/{countId}/submit")
    @PreAuthorize("hasAuthority('stock:count:warehouse_review')")
    public PeriodView submit(@PathVariable UUID countId, @RequestBody VersionRequest request) {
        return counts.submit(countId, request);
    }

    private static ResponseEntity<LineConflictBody> conflict(WorkshopMaterialCountService.LineConflict conflict) {
        return ResponseEntity.status(ErrorCode.CONFLICT.getHttpStatus()).body(new LineConflictBody(
                OffsetDateTime.now(), ErrorCode.CONFLICT.getHttpStatus(), ErrorCode.CONFLICT.name(),
                conflict.getMessage(), null, conflict.latest()));
    }
}
