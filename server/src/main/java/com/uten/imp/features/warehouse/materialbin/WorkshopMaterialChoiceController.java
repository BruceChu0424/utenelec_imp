package com.uten.imp.features.warehouse.materialbin;

import com.uten.imp.application.port.WorkshopMaterialChoicePort;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChoiceList;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.ChooseRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.MaterialChangeRequest;
import com.uten.imp.features.warehouse.materialbin.WorkshopMaterialDtos.SegmentMaterials;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;
import java.util.UUID;

/** 开工确认表的认料与段级换料 (ADR-131 §5.4、§5.5)。 */
@RestController
@RequestMapping("/api/workshop-material")
public class WorkshopMaterialChoiceController {

    private static final int MAX_SEGMENTS = 500;

    private final WorkshopMaterialChoiceAdapter choices;

    public WorkshopMaterialChoiceController(WorkshopMaterialChoiceAdapter choices) {
        this.choices = choices;
    }

    /** 这些任务段在开工确认表里的行 (按车间 + 产品聚合); 不需要确认的段不出现。 */
    @GetMapping("/choices/pending")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public List<WorkshopMaterialChoicePort.PendingChoice> pending(@RequestParam List<UUID> segmentIds) {
        if (segmentIds.size() > MAX_SEGMENTS) {
            throw new ApiException(ErrorCode.VALIDATION_FAILED, "一次最多确认 " + MAX_SEGMENTS + " 个任务");
        }
        return choices.pending(segmentIds);
    }

    @PostMapping("/choices")
    @PreAuthorize("hasAuthority('workshop_material:choose')")
    public ChoiceList choose(@RequestBody ChooseRequest request) {
        return choices.chooseAndList(request);
    }

    /** 换料对话框的底稿 (这张工单现在用的料、可换的料、最早可以从哪天起改、段的最新版本)。 */
    @GetMapping("/segments/{segmentId}/material-changes")
    @PreAuthorize("hasAuthority('workshop_material:view')")
    public SegmentMaterials segmentMaterials(@PathVariable UUID segmentId) {
        return choices.segmentMaterials(segmentId);
    }

    @PostMapping("/segments/{segmentId}/material-changes")
    @PreAuthorize("hasAuthority('workshop_material:choose')")
    public SegmentMaterials changeMaterial(@PathVariable UUID segmentId, @RequestBody MaterialChangeRequest request) {
        return choices.changeMaterial(segmentId, request);
    }
}
