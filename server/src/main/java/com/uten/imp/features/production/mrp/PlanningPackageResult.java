package com.uten.imp.features.production.mrp;

import java.util.List;
import java.util.UUID;

/** 原子计划包结果：已创建的子计划，以及可选的采购申请溯源。 */
public record PlanningPackageResult(
        UUID packageId,
        String status,
        boolean replayed,
        List<GenerateSubplansRequest.Created> subplans,
        MrpGenerateResult purchaseRequest,
        MrpGenerateResult subcontractApplication,
        MrpGenerateResult drawDocument,
        List<ExecutionSegmentResult> executionSegments,
        List<MrpGenerateResult> drawDocuments) {

    public PlanningPackageResult(
            UUID packageId,
            String status,
            boolean replayed,
            List<GenerateSubplansRequest.Created> subplans,
            MrpGenerateResult purchaseRequest,
            MrpGenerateResult drawDocument,
            List<ExecutionSegmentResult> executionSegments,
            List<MrpGenerateResult> drawDocuments) {
        this(
                packageId,
                status,
                replayed,
                subplans,
                purchaseRequest,
                null,
                drawDocument,
                executionSegments,
                drawDocuments);
    }

    public PlanningPackageResult(
            UUID packageId,
            String status,
            boolean replayed,
            List<GenerateSubplansRequest.Created> subplans,
            MrpGenerateResult purchaseRequest,
            MrpGenerateResult drawDocument) {
        this(
                packageId,
                status,
                replayed,
                subplans,
                purchaseRequest,
                null,
                drawDocument,
                List.of(),
                drawDocument == null ? List.of() : List.of(drawDocument));
    }
}
