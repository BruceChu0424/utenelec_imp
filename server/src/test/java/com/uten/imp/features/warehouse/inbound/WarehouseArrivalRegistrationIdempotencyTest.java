package com.uten.imp.features.warehouse.inbound;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.features.purchase.receipt.PurchaseReceiptService;
import com.uten.imp.features.subcontract.receipt.SubcontractReceiptService;
import com.uten.imp.features.warehouse.inbound.ProcurementArrivalContracts.WarehouseArrivalRegisterRequest;
import com.uten.imp.security.SecurityContextCurrentUser;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class WarehouseArrivalRegistrationIdempotencyTest {

    @Test
    void sameMakerKeyAndHashReplaysOriginalResultWithoutCreatingAnotherReceipt() {
        UUID makerId = UUID.randomUUID();
        UUID receiptId = UUID.randomUUID();
        WarehouseArrivalRegisterRequest request = request(
                "arrival-retry-key-001", "到货登记", new BigDecimal("5.00"));
        String hash = WarehouseArrivalRegistrationService.requestHash(request);
        var command = new WarehouseArrivalRegistrationService.ArrivalCommand(
                hash, "COMPLETED", "SUBMITTED_FOR_INSPECTION",
                receiptId, null, "PR-REPLAY-001", null);
        ReplayJdbcTemplate jdbc = new ReplayJdbcTemplate(command);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        PurchaseReceiptService purchase = mock(PurchaseReceiptService.class);
        SubcontractReceiptService subcontract = mock(SubcontractReceiptService.class);
        var service = new WarehouseArrivalRegistrationService(
                jdbc, mock(TxSessionVars.class), currentUser, purchase, subcontract);

        var result = service.register(request);

        assertThat(result.receiptId()).isEqualTo(receiptId);
        assertThat(result.receiptBillNo()).isEqualTo("PR-REPLAY-001");
        assertThat(result.outcome()).isEqualTo("SUBMITTED_FOR_INSPECTION");
        verifyNoInteractions(purchase, subcontract);
    }

    @Test
    void sameMakerKeyWithDifferentCanonicalBodyConflictsBeforeReceiptCreation() {
        UUID makerId = UUID.randomUUID();
        WarehouseArrivalRegisterRequest original = request(
                "arrival-retry-key-002", "原内容", BigDecimal.ONE);
        var command = new WarehouseArrivalRegistrationService.ArrivalCommand(
                WarehouseArrivalRegistrationService.requestHash(original),
                "COMPLETED", "SUBMITTED_FOR_INSPECTION",
                UUID.randomUUID(), null, "PR-REPLAY-002", null);
        ReplayJdbcTemplate jdbc = new ReplayJdbcTemplate(command);
        SecurityContextCurrentUser currentUser = mock(SecurityContextCurrentUser.class);
        when(currentUser.requireEmployeeId()).thenReturn(makerId);
        PurchaseReceiptService purchase = mock(PurchaseReceiptService.class);
        SubcontractReceiptService subcontract = mock(SubcontractReceiptService.class);
        var service = new WarehouseArrivalRegistrationService(
                jdbc, mock(TxSessionVars.class), currentUser, purchase, subcontract);

        assertThatThrownBy(() -> service.register(request(
                "arrival-retry-key-002", "不同内容", BigDecimal.ONE)))
                .isInstanceOfSatisfying(ApiException.class, error -> {
                    assertThat(error.getCode()).isEqualTo(ErrorCode.CONFLICT);
                    assertThat(error.getMessage()).contains("幂等键已用于不同内容");
                });
        verifyNoInteractions(purchase, subcontract);
    }

    @Test
    void canonicalHashExcludesRetryKeyAndNormalizesDecimalScale() {
        WarehouseArrivalRegisterRequest left = request(
                "arrival-retry-key-003", "同一内容", new BigDecimal("5.0"));
        WarehouseArrivalRegisterRequest right = request(
                "arrival-retry-key-004", "同一内容", new BigDecimal("5.000"));
        WarehouseArrivalRegisterRequest changed = request(
                "arrival-retry-key-003", "同一内容", new BigDecimal("6"));

        assertThat(WarehouseArrivalRegistrationService.requestHash(left))
                .isEqualTo(WarehouseArrivalRegistrationService.requestHash(right))
                .isNotEqualTo(WarehouseArrivalRegistrationService.requestHash(changed))
                .matches("[0-9a-f]{64}");
    }

    @Test
    void canonicalHashIncludesOptionalActualTotalWeight() {
        WarehouseArrivalRegisterRequest left = request(
                "arrival-retry-key-005", "同一内容", new BigDecimal("5"),
                new BigDecimal("2.5000"));
        WarehouseArrivalRegisterRequest same = request(
                "arrival-retry-key-005", "同一内容", new BigDecimal("5.0"),
                new BigDecimal("2.5"));
        WarehouseArrivalRegisterRequest changed = request(
                "arrival-retry-key-005", "同一内容", new BigDecimal("5"),
                new BigDecimal("2.6"));

        assertThat(WarehouseArrivalRegistrationService.requestHash(left))
                .isEqualTo(WarehouseArrivalRegistrationService.requestHash(same))
                .isNotEqualTo(WarehouseArrivalRegistrationService.requestHash(changed));
    }

    private static WarehouseArrivalRegisterRequest request(
            String key, String remark, BigDecimal qty) {
        return request(key, remark, qty, null);
    }

    private static WarehouseArrivalRegisterRequest request(
            String key, String remark, BigDecimal qty, BigDecimal weight) {
        return new WarehouseArrivalRegisterRequest(
                key,
                "PURCHASE",
                LocalDate.of(2026, 8, 28),
                UUID.fromString("00000000-0000-0000-0000-000000000101"),
                UUID.fromString("00000000-0000-0000-0000-000000000102"),
                UUID.fromString("00000000-0000-0000-0000-000000000103"),
                UUID.fromString("00000000-0000-0000-0000-000000000104"),
                remark,
                List.of(new WarehouseArrivalRegisterRequest.ArrivalLine(
                        UUID.fromString("00000000-0000-0000-0000-000000000105"),
                        qty,
                        UUID.fromString("00000000-0000-0000-0000-000000000106"),
                        null,
                        UUID.fromString("00000000-0000-0000-0000-000000000107"),
                        BigDecimal.ONE,
                        weight,
                        "PO-001")));
    }

    private static final class ReplayJdbcTemplate extends JdbcTemplate {
        private final WarehouseArrivalRegistrationService.ArrivalCommand command;

        private ReplayJdbcTemplate(
                WarehouseArrivalRegistrationService.ArrivalCommand command) {
            this.command = command;
        }

        @Override
        public <T> T queryForObject(
                String sql, Class<T> requiredType, Object... args) {
            if (sql.contains("pg_advisory_xact_lock")) {
                return requiredType.cast(Boolean.TRUE);
            }
            throw new AssertionError("Unexpected queryForObject: " + sql);
        }

        @Override
        @SuppressWarnings("unchecked")
        public <T> List<T> query(
                String sql, RowMapper<T> rowMapper, Object... args) {
            if (sql.contains("warehouse_arrival_registration_commands")) {
                return (List<T>) (List<?>) List.of(command);
            }
            throw new AssertionError("Unexpected query: " + sql);
        }
    }
}
