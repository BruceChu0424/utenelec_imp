package com.uten.imp.features.reporting.export;

import com.uten.imp.common.export.ExportPayload;
import com.uten.imp.application.port.MasterReportExportPort;
import com.uten.imp.application.port.WorkbenchReportExportPort;
import org.springframework.stereotype.Component;
import java.util.Set;

/** Adapts the six existing authorities, never reproduces their amount or scope rules. */
@Component
public class ReportExportSource {
    private final com.uten.imp.features.sales.report.SalesReportService sales;
    private final com.uten.imp.features.purchase.report.PurchaseReportService purchase;
    private final com.uten.imp.features.subcontract.report.SubcontractReportService subcontract;
    private final com.uten.imp.features.production.report.ProductionReportService production;
    private final com.uten.imp.features.stock.report.StockReportService stock;
    private final com.uten.imp.features.finance.report.FinanceReportService finance;
    private final com.uten.imp.features.production.report.WhereUsedExportService whereUsed;
    private final MasterReportExportPort master;
    private final WorkbenchReportExportPort workbench;
    private final AuditReportExportSource audit;
    private final ActualCostReportExportSource actualCost;
    public ReportExportSource(com.uten.imp.features.sales.report.SalesReportService sales,
            com.uten.imp.features.purchase.report.PurchaseReportService purchase,
            com.uten.imp.features.subcontract.report.SubcontractReportService subcontract,
            com.uten.imp.features.production.report.ProductionReportService production,
            com.uten.imp.features.stock.report.StockReportService stock,
            com.uten.imp.features.finance.report.FinanceReportService finance,
            com.uten.imp.features.production.report.WhereUsedExportService whereUsed,MasterReportExportPort master,
            WorkbenchReportExportPort workbench,AuditReportExportSource audit,ActualCostReportExportSource actualCost) {
        this.sales=sales;this.purchase=purchase;this.subcontract=subcontract;
        this.production=production;this.stock=stock;this.finance=finance;this.whereUsed=whereUsed;this.master=master;this.workbench=workbench;this.audit=audit;this.actualCost=actualCost;
    }
    public boolean document(ReportExportRequest request) {return Set.of("where_used","goods_actual_cost").contains(request.domain());}
    public void readDocument(ReportExportRequest request) {
        if("goods_actual_cost".equals(request.domain())) {actualCost.readDocument(request);return;}
        if(!document(request))throw new IllegalArgumentException("Unknown document export domain");
        try {
            var parameters=request.parameters();
            String material=parameters.get("materialGoodsId");
            whereUsed.streamDocument(material==null?null:java.util.UUID.fromString(material),parameters.getOrDefault("source","all"),
                    date(parameters.get("dateFrom")),date(parameters.get("dateTo")),request.sort(),request.order());
        } catch(IllegalArgumentException invalid) {
            throw new com.uten.imp.common.web.ApiException(com.uten.imp.common.web.ErrorCode.VALIDATION_FAILED,"物料反查导出条件无效");
        }
    }
    private static java.time.LocalDate date(String value) {return value==null||value.isBlank()?null:java.time.LocalDate.parse(value);}
    public ExportPayload read(ReportExportRequest r) {
        return switch(r.domain()) {
            case "sales" -> sales.export(r.report(),r.parameters(),r.sort(),r.order());
            case "purchase" -> purchase.export(r.report(),r.parameters(),r.sort(),r.order());
            case "subcontract" -> subcontract.export(r.report(),r.parameters(),r.sort(),r.order());
            case "production" -> production.export(r.report(),r.parameters(),r.sort(),r.order());
            case "stock" -> stock.export(r.report(),r.parameters(),r.sort(),r.order());
            case "finance" -> finance.export(r.report(),r.parameters(),r.sort(),r.order());
            case "master" -> master.read(r);
            case "workbench_purchase" -> workbench.read(r);
            case "audit" -> audit.read(r);
            default -> throw new IllegalArgumentException("Unknown export domain");
        };
    }
    public static String scope(String domain) { return "view_"+("stock".equals(domain)?"warehouse":domain); }
    public static String scope(ReportExportRequest request) {
        return "master".equals(request.domain())?MasterReportExportPort.projectionScope(request.report())
                :"workbench_purchase".equals(request.domain())?"view_purchase"
                :"audit".equals(request.domain())?"view_admin"
                :"goods_actual_cost".equals(request.domain())?"view_goods_cost":scope(request.domain());
    }
    public com.uten.imp.common.export.TableColumnProjection projection(ReportExportRequest request) {
        return "master".equals(request.domain())?master.projection(request):request.columnProjection();
    }
}
