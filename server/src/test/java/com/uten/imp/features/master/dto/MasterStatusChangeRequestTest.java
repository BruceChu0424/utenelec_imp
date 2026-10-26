package com.uten.imp.features.master.dto;

import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import java.util.UUID;
import java.util.stream.Stream;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class MasterStatusChangeRequestTest {
    static Stream<Arguments> commands() {
        return Stream.of(
                com.uten.imp.features.master.goods.GoodsService.class,
                com.uten.imp.features.master.mould.MouldService.class,
                com.uten.imp.features.master.client.ClientService.class,
                com.uten.imp.features.master.supplier.SupplierService.class,
                com.uten.imp.features.master.color.ColorService.class,
                com.uten.imp.features.master.unit.UnitService.class,
                com.uten.imp.features.master.currency.CurrencyService.class,
                com.uten.imp.features.master.warehouse.WarehouseService.class,
                com.uten.imp.features.master.account.AccountService.class)
                .flatMap(type -> Stream.of("unknown", "使用 ", " ")
                        .map(value -> Arguments.of(type, value)));
    }

    @ParameterizedTest @MethodSource("commands")
    void everyExplicitMasterStatusCommandRejectsInvalidValuesBeforeAnyWrite(Class<?> type, String status) throws Exception {
        Object service = mock(type, CALLS_REAL_METHODS);
        var command = type.getMethod("changeStatus", UUID.class, MasterStatusChangeRequest.class);
        var invocation = assertThrows(java.lang.reflect.InvocationTargetException.class,
                () -> command.invoke(service, UUID.randomUUID(), new MasterStatusChangeRequest(status, null)));
        ApiException error = assertInstanceOf(ApiException.class, invocation.getCause());
        assertEquals(ErrorCode.VALIDATION_FAILED, error.getCode());
    }

    @ParameterizedTest @ValueSource(strings = {"使用", "禁用"})
    void acceptsBothCanonicalStates(String status) {
        assertDoesNotThrow(() -> new MasterStatusChangeRequest(status, null).requireValidStatus());
    }

    @ParameterizedTest @NullAndEmptySource @ValueSource(strings = {" ", "unknown", "使用 ", " 禁用"})
    void missingOrNormalizedLookalikesCannotBecomeNewStates(String status) {
        assertThrows(ApiException.class, () -> new MasterStatusChangeRequest(status, null).requireValidStatus());
    }
}
