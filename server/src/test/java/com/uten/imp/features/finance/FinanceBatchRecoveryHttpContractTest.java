package com.uten.imp.features.finance;

import com.uten.imp.common.web.ApiError;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import java.util.Map;
import java.util.UUID;
import static org.assertj.core.api.Assertions.*;
import static org.mockito.Mockito.*;

class FinanceBatchRecoveryHttpContractTest {
    @Test void publishedRowLimitMatchesTheSharedGroupingContractAndServerAdmission()throws Exception {
        var contract=new com.fasterxml.jackson.databind.ObjectMapper().readTree(java.nio.file.Files.readString(java.nio.file.Path.of("../contracts/finance-entry-grouping-v1.json")));
        assertThat(contract.path("maxDocuments").asInt()).isEqualTo(FinanceBatchEntryController.MAX_DOCUMENTS);
        assertThat(FinanceBatchEntryController.Request.class.getDeclaredField("documents").getAnnotation(jakarta.validation.constraints.Size.class).max()).isEqualTo(FinanceBatchEntryController.MAX_DOCUMENTS);
    }
    @Test void allFamilyReceiptAndCancellationRoutesKeepReadPermissionWithoutRequiringCreate() {
        var permissions=Map.of("receipts","finance_receipt:view","payments","finance_payment:view","expenses","finance_expense:view","incomes","finance_other_income:view","bank-transfers","finance_bank_transfer:view");
        for(var family:permissions.entrySet()) {
            String base="/"+family.getKey()+"/batch/operations/{key}";
            var get=java.util.Arrays.stream(FinanceBatchEntryController.class.getDeclaredMethods()).filter(method->method.getAnnotation(GetMapping.class)!=null&&java.util.List.of(method.getAnnotation(GetMapping.class).value()).contains(base)).findFirst().orElseThrow();
            var cancel=java.util.Arrays.stream(FinanceBatchEntryController.class.getDeclaredMethods()).filter(method->method.getAnnotation(PostMapping.class)!=null&&java.util.List.of(method.getAnnotation(PostMapping.class).value()).contains(base+"/cancel")).findFirst().orElseThrow();
            assertThat(get.getAnnotation(PreAuthorize.class).value()).isEqualTo("hasAuthority('"+family.getValue()+"')");
            assertThat(cancel.getAnnotation(PreAuthorize.class).value()).isEqualTo(get.getAnnotation(PreAuthorize.class).value());
        }
    }
    @Test void aLateCancelledCreateIsStructuredConflictAndNeverAnEmptySuccessfulBatch() {
        var details=Map.<String,Object>of("found",true,"requestId","original-key","idempotencyKey","original-key","actorId",UUID.randomUUID(),"outcome","CANCELLED_UNWRITTEN");
        var controller=new FinanceBatchEntryController(mock(FinanceBatchEntryService.class));
        var response=controller.cancelled(new FinanceBatchEntryService.CancelledBatch(details));
        assertThat(response.getStatusCode().value()).isEqualTo(409);
        ApiError body=response.getBody();assertThat(body).isNotNull();assertThat(body.getDetails()).isEqualTo(details).doesNotContainKeys("items","result");
        assertThat(body.getCode()).isEqualTo("CONFLICT");
    }
}
