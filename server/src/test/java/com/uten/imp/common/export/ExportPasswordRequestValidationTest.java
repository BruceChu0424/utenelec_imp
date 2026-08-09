package com.uten.imp.common.export;

import com.uten.imp.audit.AuditController;
import com.uten.imp.features.finance.report.FinanceReportController;
import com.uten.imp.features.master.account.AccountController;
import com.uten.imp.features.master.client.ClientController;
import com.uten.imp.features.master.currency.CurrencyController;
import com.uten.imp.features.master.goods.GoodsBomController;
import com.uten.imp.features.master.goods.GoodsController;
import com.uten.imp.features.master.supplier.SupplierController;
import com.uten.imp.features.production.report.ProductionReportController;
import com.uten.imp.features.purchase.report.PurchaseReportController;
import com.uten.imp.features.sales.report.SalesReportController;
import com.uten.imp.features.stock.report.StockReportController;
import com.uten.imp.features.subcontract.report.SubcontractReportController;
import jakarta.validation.Valid;
import jakarta.validation.Validation;
import jakarta.validation.Validator;
import org.junit.jupiter.api.Test;

import java.lang.reflect.Parameter;
import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class ExportPasswordRequestValidationTest {

    private final Validator validator =
            Validation.buildDefaultValidatorFactory().getValidator();

    @Test
    void passwordIsOptionalAndOnlyHasAnUpperLengthBound() {
        assertTrue(validator.validate(new ExportPasswordRequest(null)).isEmpty());
        assertTrue(validator.validate(new ExportPasswordRequest("")).isEmpty());
        assertTrue(validator.validate(new ExportPasswordRequest(" ")).isEmpty());
        assertTrue(validator.validate(new ExportPasswordRequest("x")).isEmpty());
        assertTrue(validator.validate(new ExportPasswordRequest("x".repeat(128))).isEmpty());
        assertFalse(validator.validate(new ExportPasswordRequest("x".repeat(129))).isEmpty());
    }

    @Test
    void everyExportEndpointActivatesBeanValidation() {
        List<Class<?>> controllers = List.of(
                AuditController.class,
                FinanceReportController.class,
                AccountController.class,
                ClientController.class,
                CurrencyController.class,
                GoodsBomController.class,
                GoodsController.class,
                SupplierController.class,
                ProductionReportController.class,
                PurchaseReportController.class,
                SalesReportController.class,
                StockReportController.class,
                SubcontractReportController.class);

        int endpoints = 0;
        for (Class<?> controller : controllers) {
            for (var method : controller.getDeclaredMethods()) {
                for (Parameter parameter : method.getParameters()) {
                    if (parameter.getType() == ExportPasswordRequest.class) {
                        endpoints++;
                        assertTrue(
                                parameter.isAnnotationPresent(Valid.class),
                                controller.getSimpleName() + "." + method.getName());
                    }
                }
            }
        }
        assertEquals(13, endpoints);
    }
}
