package com.uten.imp.features.master.goods;

import com.uten.imp.features.master.goods.dto.BomBatchMaintenanceRequest;
import jakarta.validation.Validation;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.UUID;
import java.util.stream.IntStream;

import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

class BomBatchMaintenanceRequestValidationTest {
    @Test void removalRetainsTheExistingFiveHundredDirectRelationsLimit() {
        List<UUID> ids=IntStream.rangeClosed(1,501).mapToObj(i->new UUID(0,i)).toList();
        try(var factory=Validation.buildDefaultValidatorFactory()) {
            var validator=factory.getValidator();
            assertTrue(validator.validate(new BomBatchMaintenanceRequest(BomBatchMaintenanceRequest.Action.REMOVE,
                    List.of(UUID.randomUUID()),null,ids.subList(0,500))).isEmpty());
            assertFalse(validator.validate(new BomBatchMaintenanceRequest(BomBatchMaintenanceRequest.Action.REMOVE,
                    List.of(UUID.randomUUID()),null,ids)).isEmpty());
        }
    }
}
