package com.uten.imp.features.master.client;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.features.master.client.dto.ClientSaveRequest;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.security.core.context.SecurityContextHolder;
import java.math.BigDecimal;
import static org.junit.jupiter.api.Assertions.*;

class ClientFinancialFieldBoundaryTest {
    @AfterEach void clear() { SecurityContextHolder.clearContext(); }
    @Test void omittedFieldsAreNotClearedAndExplicitNullIsProtected() throws Exception {
        var client=new Client();client.setBank("保留银行");client.setCreditFloor(new BigDecimal("100"));
        var mapper=new ObjectMapper();
        ClientService.requireFinancialUnchanged(client,mapper.readValue("{}",ClientSaveRequest.class));
        ClientService.requireFinancialUnchanged(client,mapper.readValue("{\"creditFloor\":100.0000}",ClientSaveRequest.class));
        assertThrows(ApiException.class,()->ClientService.requireFinancialUnchanged(client,mapper.readValue("{\"bank\":null}",ClientSaveRequest.class)));
        assertThrows(ApiException.class,()->ClientService.requireFinancialUnchanged(client,mapper.readValue("{\"creditFloor\":0}",ClientSaveRequest.class)));
    }
    @Test void legacyCreateBodyMayContainEmptyAndZeroFinancialDefaults() throws Exception {
        var mapper=new ObjectMapper();
        ClientService.requireNewFinancialDefaults(mapper.readValue("{\"bank\":\"\",\"bankAccount\":null,\"taxId\":null,\"credit\":0,\"initTotal\":0,\"tday\":0,\"creditFloor\":null,\"defaultCurrencyId\":null,\"defaultSettlementMethodId\":null}",ClientSaveRequest.class));
        assertThrows(ApiException.class,()->ClientService.requireNewFinancialDefaults(mapper.readValue("{\"initTotal\":1}",ClientSaveRequest.class)));
    }
}
