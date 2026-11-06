package com.uten.imp.features.production.dailyreport;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDraftClaim;
import com.uten.imp.features.production.dailyreport.dto.DailyReportListItem;
import com.uten.imp.features.production.dailyreport.dto.DailyReportDraftClaimsHeader;
import java.time.LocalDate;
import java.util.List;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class DailyReportDraftClaimsJsonTest {
    private final ObjectMapper json = new ObjectMapper().findAndRegisterModules();

    @Test void existingConstructorAndDefaultJsonHaveNoOptionalClaimFields() {
        var header = header();
        var body = json.valueToTree(header);
        assertFalse(body.has("draftClaimsVersion"));
        assertFalse(body.has("draftClaims"));
        assertEquals(header.getId().toString(), body.path("id").asText());
    }

    @Test void versionOneCarriesExactDecimalTextAndExplicitNulls() {
        var header = header();
        header.setDraftClaimsVersion(1);
        header.setDraftClaims(List.of(new DailyReportDraftClaim(null, null, true),
                new DailyReportDraftClaim(UUID.randomUUID(), "90071992547409.1234", false)));
        var body = json.valueToTree(header);
        assertEquals(1, body.path("draftClaimsVersion").asInt());
        var empty = body.path("draftClaims").get(0);
        assertTrue(empty.has("executionSegmentId"));assertTrue(empty.get("executionSegmentId").isNull());
        assertTrue(empty.has("qty"));assertTrue(empty.get("qty").isNull());
        assertTrue(empty.path("actualSurplus").asBoolean());
        assertTrue(body.path("draftClaims").get(1).path("qty").isTextual());
        assertEquals("90071992547409.1234", body.path("draftClaims").get(1).path("qty").asText());
    }

    @Test void selectedHeaderVersionsStayExactTextBeyondTheJavascriptIntegerBoundary() throws Exception {
        var header=new DailyReportDraftClaimsHeader(UUID.randomUUID(),"SR20261105000001",LocalDate.of(2026,11,5),
                (short)0,false,false,"9007199254740993",1,"a".repeat(64),
                List.of(new DailyReportDraftClaim(null,"90071992547409.1234",false)));
        var body=json.readTree(json.writeValueAsBytes(header));
        assertTrue(body.path("rowVersion").isTextual());assertEquals("9007199254740993",body.path("rowVersion").textValue());
        assertEquals("90071992547409.1234",body.path("draftClaims").get(0).path("qty").textValue());
        assertEquals(1,body.path("draftClaimsVersion").asInt());assertEquals("a".repeat(64),body.path("draftClaimsFingerprint").textValue());
        assertFalse(body.has("warehouseName"));assertFalse(body.has("remark"));
    }

    private DailyReportListItem header() {
        return new DailyReportListItem(UUID.randomUUID(), "DR-CLAIM", LocalDate.of(2026,11,5),
                null,null,null,null,null,(short)0,false,false,null);
    }
}
