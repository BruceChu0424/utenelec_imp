package com.uten.imp.features.production.execution;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.TestFactory;
import java.util.stream.Stream;
import java.util.stream.StreamSupport;
import static org.junit.jupiter.api.Assertions.*;

class ProductionWorkshopTaskStageContractTest {
    @TestFactory Stream<DynamicTest> workshopPageAndExportUseTheSameServerFactStages() throws Exception {
        var mapper = new ObjectMapper().findAndRegisterModules();
        try (var input = getClass().getResourceAsStream("/contracts/workshop-task-stage-v1.json")) {
            assertNotNull(input);
            var fixture = mapper.readTree(input);
            assertEquals(1, fixture.path("contractVersion").asInt());
            return StreamSupport.stream(fixture.path("cases").spliterator(), false).map(test ->
                    DynamicTest.dynamicTest(test.path("name").asText(), () -> {
                        var task = mapper.treeToValue(test.path("task"), ProductionExecutionWorkbenchSegment.class);
                        assertEquals(test.path("label").asText(), ProductionWorkshopTaskStage.label(task));
                        assertEquals(test.path("label").asText(), ProductionWorkshopTaskExportService.row(task).get("status"));
                    }));
        }
    }
}
