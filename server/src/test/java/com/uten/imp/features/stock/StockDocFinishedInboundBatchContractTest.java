package com.uten.imp.features.stock;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmRequest;
import com.uten.imp.features.stock.dto.FinishedInboundBatchConfirmResponse;
import org.junit.jupiter.api.Test;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.PostMapping;

import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.junit.jupiter.api.Assertions.assertThrows;

class StockDocFinishedInboundBatchContractTest {

    @Test
    void requestNormalizationIsOrderIndependentAndRejectsDuplicates() {
        UUID first = UUID.fromString(
                "10000000-0000-0000-0000-000000000001");
        UUID second = UUID.fromString(
                "20000000-0000-0000-0000-000000000001");
        FinishedInboundBatchConfirmRequest forward = request(
                "batch-confirm-key-01", List.of(first, second));
        FinishedInboundBatchConfirmRequest reverse = request(
                "batch-confirm-key-01", List.of(second, first));

        StockDocService.FinishedInboundBatchCommand normalizedForward =
                StockDocService.normalizeFinishedInboundBatchRequest(forward);
        StockDocService.FinishedInboundBatchCommand normalizedReverse =
                StockDocService.normalizeFinishedInboundBatchRequest(reverse);

        assertThat(normalizedForward.documentIds())
                .containsExactly(first, second);
        assertThat(normalizedReverse.requestHash())
                .isEqualTo(normalizedForward.requestHash());
        assertThrows(
                ApiException.class,
                () -> StockDocService.normalizeFinishedInboundBatchRequest(
                        request("batch-confirm-key-02", List.of(first, first))));
    }

    @Test
    void requestNormalizationEnforcesFiftyDocumentLimit() {
        List<UUID> ids = new ArrayList<>();
        for (int index = 0; index < 51; index++) {
            ids.add(new UUID(0, index + 1L));
        }

        assertThrows(
                ApiException.class,
                () -> StockDocService.normalizeFinishedInboundBatchRequest(
                        request("batch-confirm-key-03", ids)));
    }

    @Test
    void endpointAndServiceKeepApprovePermissionAndOneTransaction()
            throws Exception {
        Method controller = StockDocController.class.getMethod(
                "confirmFinishedInboundBatch",
                FinishedInboundBatchConfirmRequest.class);
        Method service = StockDocService.class.getMethod(
                "confirmFinishedInboundBatch",
                FinishedInboundBatchConfirmRequest.class);

        assertThat(controller.getAnnotation(PostMapping.class).value())
                .containsExactly("/finished-in/confirm-batch");
        assertThat(controller.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock_doc:approve')");
        assertThat(service.getAnnotation(PreAuthorize.class).value())
                .isEqualTo("hasAuthority('stock_doc:approve')");
        assertThat(service.getAnnotation(Transactional.class)).isNotNull();
        assertThat(FinishedInboundBatchConfirmResponse.Item.class
                .getRecordComponents())
                .extracting(component -> component.getName())
                .containsExactly("documentId", "billNo", "status");
    }

    @Test
    void secondDocumentFailureCannotBeCaughtOrPersistPartialBatch()
            throws Exception {
        String source = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/stock/StockDocService.java"));
        int start = source.indexOf(
                "public FinishedInboundBatchConfirmResponse "
                        + "confirmFinishedInboundBatch(");
        int end = source.indexOf(
                "public StockDocDetail confirmFinishedInbound(", start);
        String batch = source.substring(start, end);

        assertThat(batch.indexOf("prelockProductionDocuments("))
                .isGreaterThan(batch.indexOf("findFinishedInboundBatchReplay("));
        assertThat(batch.indexOf("for (UUID documentId"))
                .isGreaterThan(batch.indexOf("prelockProductionDocuments("));
        assertThat(batch)
                .contains("confirmFinishedInboundAfterPrelock(")
                .contains("insertFinishedInboundBatch(")
                .doesNotContain("catch (")
                .doesNotContain("REQUIRES_NEW")
                .doesNotContain("varianceReason");
        assertThat(batch.indexOf("insertFinishedInboundBatch("))
                .isGreaterThan(batch.indexOf("confirmFinishedInboundAfterPrelock("));
        assertThat(source)
                .contains(".distinct()\n                .sorted()")
                .contains("PRODUCTION_FINISHED_IN_CONFIRM_BATCH_LOCK_ORDER")
                .contains("该批量点收幂等键已用于不同单据集合")
                .contains("fullFinishedInboundAcceptanceRequest(")
                .contains("line.setAcceptedQty(item.getQty())");
    }

    private static FinishedInboundBatchConfirmRequest request(
            String key, List<UUID> ids) {
        FinishedInboundBatchConfirmRequest request =
                new FinishedInboundBatchConfirmRequest();
        request.setIdempotencyKey(key);
        request.setDocumentIds(ids);
        return request;
    }
}
