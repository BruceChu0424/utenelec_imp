package com.uten.imp.features;

import com.uten.imp.audit.AuditDetailViewRecorder;
import com.uten.imp.audit.AuditService;
import com.uten.imp.common.export.WorkbookDownloadService;
import com.uten.imp.common.export.XlsxExportService;
import com.uten.imp.features.master.clientcategory.ClientCategoryController;
import com.uten.imp.features.master.clientcategory.ClientCategoryService;
import com.uten.imp.features.master.clientcategory.dto.ClientCategoryDetail;
import com.uten.imp.features.master.color.ColorController;
import com.uten.imp.features.master.color.ColorService;
import com.uten.imp.features.master.color.dto.ColorDetail;
import com.uten.imp.features.master.currency.CurrencyController;
import com.uten.imp.features.master.currency.CurrencyService;
import com.uten.imp.features.master.currency.dto.CurrencyDetail;
import com.uten.imp.features.master.goods.GoodsController;
import com.uten.imp.features.master.goods.GoodsService;
import com.uten.imp.features.master.goods.dto.GoodsDetail;
import com.uten.imp.features.master.materialcategory.MaterialCategoryController;
import com.uten.imp.features.master.materialcategory.MaterialCategoryService;
import com.uten.imp.features.master.materialcategory.dto.MaterialCategoryDetail;
import com.uten.imp.features.master.mould.MouldController;
import com.uten.imp.features.master.mould.MouldService;
import com.uten.imp.features.master.mould.dto.MouldDetail;
import com.uten.imp.features.master.mouldcategory.MouldCategoryController;
import com.uten.imp.features.master.mouldcategory.MouldCategoryService;
import com.uten.imp.features.master.mouldcategory.dto.MouldCategoryDetail;
import com.uten.imp.features.master.paymentstyle.PaymentStyleController;
import com.uten.imp.features.master.paymentstyle.PaymentStyleService;
import com.uten.imp.features.master.paymentstyle.dto.PaymentStyleDetail;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryController;
import com.uten.imp.features.master.suppliercategory.SupplierCategoryService;
import com.uten.imp.features.master.suppliercategory.dto.SupplierCategoryDetail;
import com.uten.imp.features.master.unit.UnitController;
import com.uten.imp.features.master.unit.UnitService;
import com.uten.imp.features.master.unit.dto.UnitDetail;
import com.uten.imp.features.master.warehouse.WarehouseController;
import com.uten.imp.features.master.warehouse.WarehouseService;
import com.uten.imp.features.master.warehouse.dto.WarehouseDetail;
import com.uten.imp.features.org.department.DepartmentController;
import com.uten.imp.features.org.department.DepartmentService;
import com.uten.imp.features.org.department.WorkforceOverviewService;
import com.uten.imp.features.org.department.dto.DepartmentDetail;
import com.uten.imp.features.production.analysis.MaterialAnalysisCommandService;
import com.uten.imp.features.production.analysis.MaterialAnalysisContracts.AnalysisView;
import com.uten.imp.features.production.analysis.MaterialAnalysisController;
import com.uten.imp.features.production.analysis.MaterialAnalysisService;
import com.uten.imp.features.production.analysis.MaterialAnalysisSupplyProgressService;
import com.uten.imp.features.production.analysis.MaterialStockReallocationService;
import com.uten.imp.features.production.mrp.ProductionGoodsWorkshopPreferenceService;
import com.uten.imp.features.suggestion.SuggestionController;
import com.uten.imp.features.suggestion.SuggestionService;
import com.uten.imp.features.suggestion.dto.SuggestionDto;
import com.uten.imp.features.visitor.VisitorApplicationService;
import com.uten.imp.features.visitor.VisitorController;
import com.uten.imp.features.visitor.dto.VisitorApplyDto.VisitorDetail;
import com.uten.imp.security.SecurityContextCurrentUser;
import org.junit.jupiter.api.Test;

import java.util.UUID;

import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class LowSensitivityDetailViewAuditControllerTest {

    private final AuditDetailViewRecorder recorder = mock(AuditDetailViewRecorder.class);
    private final AuditService audit = mock(AuditService.class);
    private final SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);

    @Test
    void flatMasterDetailsRecordCodeOrSafeNameOnlyAfterSuccessfulLookup() {
        UUID goodsId = UUID.randomUUID();
        GoodsService goodsService = mock(GoodsService.class);
        GoodsDetail goods = mock(GoodsDetail.class);
        when(goods.getCode()).thenReturn("G-001");
        when(goods.getLegacyId()).thenReturn(1);
        when(goodsService.detail(goodsId)).thenReturn(goods);
        assertSame(goods, goodsController(goodsService).detail(goodsId));
        verify(recorder).record(
                "view_goods_detail", "goods", goodsId, "G-001", 1, "货品");

        UUID mouldId = UUID.randomUUID();
        MouldService mouldService = mock(MouldService.class);
        MouldDetail mould = mock(MouldDetail.class);
        when(mould.getCode()).thenReturn(" ");
        when(mould.getName()).thenReturn("模具A");
        when(mould.getLegacyId()).thenReturn(2);
        when(mouldService.detail(mouldId)).thenReturn(mould);
        assertSame(mould, new MouldController(mouldService, recorder).detail(mouldId));
        verify(recorder).record(
                "view_mould_detail", "moulds", mouldId, "模具A", 2, "模具");

        UUID currencyId = UUID.randomUUID();
        CurrencyService currencyService = mock(CurrencyService.class);
        CurrencyDetail currency = mock(CurrencyDetail.class);
        when(currency.getCode()).thenReturn("CNY");
        when(currency.getLegacyId()).thenReturn(3);
        when(currencyService.detail(currencyId)).thenReturn(currency);
        assertSame(currency, currencyController(currencyService).detail(currencyId));
        verify(recorder).record(
                "view_currency_detail", "currencies", currencyId, "CNY", 3, "币种");

        UUID paymentStyleId = UUID.randomUUID();
        PaymentStyleService paymentStyleService = mock(PaymentStyleService.class);
        PaymentStyleDetail paymentStyle = mock(PaymentStyleDetail.class);
        when(paymentStyle.getCode()).thenReturn("PAY-01");
        when(paymentStyle.getLegacyId()).thenReturn(4);
        when(paymentStyleService.detail(paymentStyleId)).thenReturn(paymentStyle);
        assertSame(paymentStyle,
                new PaymentStyleController(paymentStyleService, recorder).detail(paymentStyleId));
        verify(recorder).record(
                "view_payment_style_detail", "payment_styles", paymentStyleId,
                "PAY-01", 4, "收付款类别");

        UUID warehouseId = UUID.randomUUID();
        WarehouseService warehouseService = mock(WarehouseService.class);
        WarehouseDetail warehouse = mock(WarehouseDetail.class);
        when(warehouse.getCode()).thenReturn("WH-01");
        when(warehouse.getLegacyId()).thenReturn(5);
        when(warehouseService.detail(warehouseId)).thenReturn(warehouse);
        assertSame(warehouse,
                new WarehouseController(warehouseService, recorder).detail(warehouseId));
        verify(recorder).record(
                "view_warehouse_detail", "warehouses", warehouseId, "WH-01", 5, "仓库");

        UUID colorId = UUID.randomUUID();
        ColorService colorService = mock(ColorService.class);
        ColorDetail color = mock(ColorDetail.class);
        when(color.getCode()).thenReturn("RED");
        when(color.getLegacyId()).thenReturn(6);
        when(colorService.detail(colorId)).thenReturn(color);
        assertSame(color, new ColorController(colorService, recorder).detail(colorId));
        verify(recorder).record(
                "view_color_detail", "colors", colorId, "RED", 6, "颜色");

        UUID unitId = UUID.randomUUID();
        UnitService unitService = mock(UnitService.class);
        UnitDetail unit = mock(UnitDetail.class);
        when(unit.getCode()).thenReturn("PCS");
        when(unit.getLegacyId()).thenReturn(7);
        when(unitService.detail(unitId)).thenReturn(unit);
        assertSame(unit, new UnitController(unitService, recorder).detail(unitId));
        verify(recorder).record(
                "view_unit_detail", "units", unitId, "PCS", 7, "计量单位");
    }

    @Test
    void categoryDetailsRecordOnlyCategoryCodeAndLegacyIdentity() {
        UUID materialId = UUID.randomUUID();
        MaterialCategoryService materialService = mock(MaterialCategoryService.class);
        MaterialCategoryDetail material = mock(MaterialCategoryDetail.class);
        when(material.getCode()).thenReturn("MAT-01");
        when(material.getLegacyId()).thenReturn(11);
        when(materialService.detail(materialId)).thenReturn(material);
        assertSame(material,
                new MaterialCategoryController(materialService, recorder).detail(materialId));
        verify(recorder).record(
                "view_material_category_detail", "material_categories", materialId,
                "MAT-01", 11, "物料分类");

        UUID mouldId = UUID.randomUUID();
        MouldCategoryService mouldService = mock(MouldCategoryService.class);
        MouldCategoryDetail mould = mock(MouldCategoryDetail.class);
        when(mould.getCode()).thenReturn("MC-01");
        when(mould.getLegacyId()).thenReturn(12);
        when(mouldService.detail(mouldId)).thenReturn(mould);
        assertSame(mould,
                new MouldCategoryController(mouldService, recorder).detail(mouldId));
        verify(recorder).record(
                "view_mould_category_detail", "mould_categories", mouldId,
                "MC-01", 12, "模具分类");

        UUID clientId = UUID.randomUUID();
        ClientCategoryService clientService = mock(ClientCategoryService.class);
        ClientCategoryDetail client = mock(ClientCategoryDetail.class);
        when(client.getCode()).thenReturn("CC-01");
        when(client.getLegacyId()).thenReturn(13);
        when(clientService.detail(clientId)).thenReturn(client);
        assertSame(client,
                new ClientCategoryController(clientService, recorder).detail(clientId));
        verify(recorder).record(
                "view_client_category_detail", "client_categories", clientId,
                "CC-01", 13, "客户分类");

        UUID supplierId = UUID.randomUUID();
        SupplierCategoryService supplierService = mock(SupplierCategoryService.class);
        SupplierCategoryDetail supplier = mock(SupplierCategoryDetail.class);
        when(supplier.getCode()).thenReturn("SC-01");
        when(supplier.getLegacyId()).thenReturn(14);
        when(supplierService.detail(supplierId)).thenReturn(supplier);
        assertSame(supplier,
                new SupplierCategoryController(supplierService, recorder).detail(supplierId));
        verify(recorder).record(
                "view_supplier_category_detail", "supplier_categories", supplierId,
                "SC-01", 14, "供应商分类");
    }

    @Test
    void auxiliaryDetailsAvoidFreeTextTitlesAndContent() {
        UUID departmentId = UUID.randomUUID();
        DepartmentService departmentService = mock(DepartmentService.class);
        DepartmentDetail department = mock(DepartmentDetail.class);
        when(department.getCode()).thenReturn("D-01");
        when(departmentService.detail(departmentId)).thenReturn(department);
        assertSame(department, new DepartmentController(
                departmentService, mock(WorkforceOverviewService.class), recorder)
                .detail(departmentId));
        verify(recorder).record(
                "view_department_detail", "departments", departmentId,
                "D-01", null, "部门");

        UUID suggestionId = UUID.randomUUID();
        SuggestionService suggestionService = mock(SuggestionService.class);
        SuggestionDto suggestion = mock(SuggestionDto.class);
        when(suggestionService.getById(suggestionId)).thenReturn(suggestion);
        assertSame(suggestion,
                new SuggestionController(suggestionService, recorder).detail(suggestionId));
        verify(recorder).record(
                "view_suggestion_detail", "suggestions", suggestionId,
                null, null, "建议");
        verify(suggestion, never()).title();
        verify(suggestion, never()).content();

        UUID visitorId = UUID.randomUUID();
        VisitorApplicationService visitorService = mock(VisitorApplicationService.class);
        VisitorDetail visitor = mock(VisitorDetail.class);
        when(visitorService.getDetail(visitorId)).thenReturn(visitor);
        assertSame(visitor,
                new VisitorController(visitorService, recorder).detail(visitorId));
        verify(recorder).record(
                "view_visitor_application_detail", "visitor_applications", visitorId,
                null, null, "访客申请");
        verify(visitor, never()).visitorName();
        verify(visitor, never()).phone();
        verify(visitor, never()).idCardLast4();
        verify(visitor, never()).visitPurpose();

        UUID analysisId = UUID.randomUUID();
        MaterialAnalysisService analysisService = mock(MaterialAnalysisService.class);
        AnalysisView analysis = mock(AnalysisView.class);
        when(analysisService.detail(analysisId)).thenReturn(analysis);
        MaterialAnalysisController analysisController = new MaterialAnalysisController(
                analysisService,
                mock(MaterialAnalysisCommandService.class),
                mock(MaterialStockReallocationService.class),
                mock(ProductionGoodsWorkshopPreferenceService.class),
                mock(MaterialAnalysisSupplyProgressService.class),
                mock(com.uten.imp.features.production.analysis.SubcontractMakeTaskService.class),
                recorder);
        assertSame(analysis, analysisController.detail(analysisId));
        verify(recorder).record(
                "view_material_analysis_detail", "production_material_analyses", analysisId,
                null, null, "物料分析");
        verify(analysis, never()).products();
    }

    @Test
    void failedDetailLookupNeverWritesSuccessfulViewAudit() {
        UUID missingId = UUID.randomUUID();
        GoodsService goodsService = mock(GoodsService.class);
        when(goodsService.detail(missingId)).thenThrow(new IllegalStateException("missing"));

        assertThrows(IllegalStateException.class,
                () -> goodsController(goodsService).detail(missingId));
        verifyNoInteractions(recorder);
    }

    private GoodsController goodsController(GoodsService service) {
        return new GoodsController(
                service,
                mock(XlsxExportService.class),
                mock(WorkbookDownloadService.class),
                audit,
                currentUser,
                recorder);
    }

    private CurrencyController currencyController(CurrencyService service) {
        return new CurrencyController(
                service,
                mock(XlsxExportService.class),
                mock(WorkbookDownloadService.class),
                audit,
                currentUser,
                recorder);
    }
}
