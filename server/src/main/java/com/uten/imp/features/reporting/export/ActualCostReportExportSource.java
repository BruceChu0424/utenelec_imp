package com.uten.imp.features.reporting.export;

import com.uten.imp.application.port.GoodsActualCostQueryPort;
import com.uten.imp.common.export.*;
import com.uten.imp.common.report.ReportQueryKit;
import com.uten.imp.common.web.*;
import com.uten.imp.application.port.GoodsActualCostSnapshotExportPort;
import com.uten.imp.security.*;
import org.springframework.stereotype.Component;
import java.util.*;

/** Exports the same inspected actual-cost digest and frozen-section projection as the original endpoint. */
@Component
public class ActualCostReportExportSource {
    private final GoodsActualCostSnapshotExportPort actual;
    private final ExportDocumentProjectionService projections;
    public ActualCostReportExportSource(GoodsActualCostSnapshotExportPort actual,ExportDocumentProjectionService projections){this.actual=actual;this.projections=projections;}
    public record Input(GoodsActualCostQueryPort.Query query,String expectedDigest) { }
    public static void authorize(AuthUser user) {
        if(user.isVisitor()||user.isMustChangePassword()||!user.isAccountNonLocked()||user.getImpersonatedBy()!=null
                ||!user.getPermissions().containsAll(Set.of("goods:view","goods:cost:view","goods:cost:export")))throw new ApiException(ErrorCode.FORBIDDEN);
    }
    public static Input input(ReportExportRequest request) {
        var p=request.parameters();
        if(!"snapshot".equals(request.report())||!Set.of("goodsId","executionSegmentId","from","to","revisionId","expectedDigest").containsAll(p.keySet()))throw invalid();
        String digest=p.get("expectedDigest");
        if(digest==null||!digest.matches("[0-9a-f]{64}"))throw invalid();
        try {
            var goods=ReportQueryKit.parseUuid(p.get("goodsId"));
            var from=ReportQueryKit.parseDate(p.get("from"));var to=ReportQueryKit.parseDate(p.get("to"));
            if(goods==null||from!=null&&to!=null&&from.isAfter(to))throw invalid();
            return new Input(new GoodsActualCostQueryPort.Query(goods,ReportQueryKit.parseUuid(p.get("executionSegmentId")),from,to,
                    ReportQueryKit.parseUuid(p.get("revisionId"))),digest);
        }catch(IllegalArgumentException|java.time.DateTimeException failure){throw invalid();}
    }
    public void readDocument(ReportExportRequest request) {
        CurrentAuthorityGuard.requireAll("goods:view","goods:cost:view","goods:cost:export");
        var input=input(request);var destination=DocumentPageSink.current();
        if(destination==null)throw new IllegalStateException("Actual-cost export requires its document sink");
        String key=request.columnProjection()==null?null:request.columnProjection().tableKey();
        String section=key!=null&&key.endsWith(".1")?"产出与撤回":key!=null&&key.endsWith(".2")?"成本对象":"物料及费用来源";
        try(var sink=DocumentPageSink.open(projections.stream(destination,request.columnProjection(),section,"view_goods_cost"))) {
            actual.streamExport(input.query(),input.expectedDigest(),ExportDocument.MAX_SECTION_ROWS);
        }
    }
    private static ApiException invalid(){return new ApiException(ErrorCode.VALIDATION_FAILED,"请先载入并核对实际成本结果再下载");}
}
