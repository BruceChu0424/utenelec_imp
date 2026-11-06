package com.uten.imp.common.report;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.uten.imp.common.finance.FinancialJsonResults;
import org.junit.jupiter.api.Test;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.util.LinkedHashMap;
import static org.junit.jupiter.api.Assertions.*;

class ReportQueryKitFrozenExactTextTest {
    @Test void legacyLiteralNumericFieldsStayUnchangedWhileWireGetsLosslessDecimalAndLargeIntegerAliases() throws Exception {
        var json=new ObjectMapper();
        var row=FinancialJsonResults.object(json,"{\"amount\":999999999999.123456789012345678900,\"count\":9007199254740993,\"huge\":9999999999999999999999999,\"raw\":\"0.0000\"}");
        var before=new LinkedHashMap<>(row);
        ReportQueryKit.includeFrozenDecimalTexts(row);
        before.forEach((key,value)->assertEquals(value,row.get(key)));
        assertEquals(new BigDecimal("999999999999.123456789012345678900"),row.get("amount"));
        assertEquals("999999999999.123456789012345678900",row.get("amountExact"));
        assertEquals("9007199254740993",row.get("countExact"));
        assertEquals("9999999999999999999999999",row.get("hugeExact"));
        assertEquals(new BigInteger("9999999999999999999999999"),row.get("huge"));
        String wire=json.writeValueAsString(row);
        assertTrue(wire.contains("\"count\":9007199254740993"));
        assertTrue(wire.contains("\"countExact\":\"9007199254740993\""));
        assertTrue(wire.contains("\"amountExact\":\"999999999999.123456789012345678900\""));
    }
    @Test void existingFrozenExactEvidenceAndMaskedMainNullAreNeverOverwrittenOrUnmasked() {
        var row=new LinkedHashMap<String,Object>();
        row.put("amount",new BigDecimal("0.1"));row.put("amountExact","0.100000000000000000001");
        row.put("masked",null);row.put("maskedExact","original-private-proof");
        row.put("nullable",new BigDecimal("2.00"));row.put("nullableExact",null);
        ReportQueryKit.includeFrozenDecimalTexts(row);
        assertEquals("0.100000000000000000001",row.get("amountExact"));
        assertNull(row.get("masked"));assertEquals("original-private-proof",row.get("maskedExact"));
        assertTrue(row.containsKey("nullableExact"));assertNull(row.get("nullableExact"));
    }
    @Test void ordinaryReportsKeepTheirExistingDefaultPolicyAndBinaryNumbersDoNotGainInventedPrecision() {
        var ordinary=new LinkedHashMap<String,Object>();ordinary.put("amount",new BigDecimal("2.000"));ordinary.put("amountExact","old");ordinary.put("count",9007199254740993L);
        ReportQueryKit.includeDecimalTexts(ordinary);
        assertEquals("2.000",ordinary.get("amountExact"));assertFalse(ordinary.containsKey("countExact"));
        var legacy=new LinkedHashMap<String,Object>();legacy.put("binary",0.1d);legacy.put("finite",42L);
        ReportQueryKit.includeFrozenDecimalTexts(legacy);
        assertEquals(0.1d,legacy.get("binary"));assertFalse(legacy.containsKey("binaryExact"));assertFalse(legacy.containsKey("finiteExact"));
    }
}
