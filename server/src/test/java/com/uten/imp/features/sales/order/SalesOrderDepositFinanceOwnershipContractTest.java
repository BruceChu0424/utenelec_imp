package com.uten.imp.features.sales.order;

import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.assertj.core.api.Assertions.assertThat;

class SalesOrderDepositFinanceOwnershipContractTest {
    @Test
    void salesCannotCreateOrRewriteCustomerAdvanceMoneyFacts() throws IOException {
        String service = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/sales/order/SalesOrderService.java"),
                StandardCharsets.UTF_8);
        String request = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/sales/order/dto/OrderSaveRequest.java"),
                StandardCharsets.UTF_8);
        String detail = Files.readString(Path.of(
                "src/main/java/com/uten/imp/features/sales/order/dto/OrderDetail.java"),
                StandardCharsets.UTF_8);

        assertThat(service)
                .doesNotContain("o.setDeposit(req.getDeposit())")
                .contains("o.setDeposit(BigDecimal.ZERO.setScale(4))")
                .contains("assertNoApprovedCustomerPrepayment(id)");
        assertThat(request).contains("@Deprecated", "Compatibility input only");
        assertThat(detail).contains("legacyDepositSnapshot").doesNotContain("private BigDecimal deposit;");
    }
}
