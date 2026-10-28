package com.uten.imp.features.org.employee;

import com.uten.imp.common.util.IdCardUtil;
import com.uten.imp.common.web.ApiException;
import com.uten.imp.common.web.ErrorCode;
import com.uten.imp.security.TxSessionVars;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.NullAndEmptySource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.Mockito.*;

class EmployeeNameReviewPolicyTest {
    private static final String EXISTING="11010519491231002X";
    private static final String OTHER="110105199001010010";
    private final FakeJdbc jdbc=new FakeJdbc();
    private final TxSessionVars tx=mock(TxSessionVars.class);
    private final EmployeeNameReviewPolicy policy=new EmployeeNameReviewPolicy(jdbc,tx);

    @Test void noSameNameDoesNotApplyANewGlobalDocumentBan() {
        assertDoesNotThrow(()->policy.requireNewIdentity("新员工","其他",null,false,null));
        verifyNoInteractions(tx);
        assertEquals(1,jdbc.locks);
    }

    @ParameterizedTest @NullAndEmptySource @ValueSource(strings={" ","\t"})
    void blankNameIsStillRejected(String name) {
        assertEquals(ErrorCode.VALIDATION_FAILED,assertThrows(ApiException.class,
                ()->policy.requireNewIdentity(name,"身份证",OTHER,false,null)).getCode());
        assertEquals(0,jdbc.locks);
    }

    @Test void duplicateNameRequiresExplicitReviewBeforeAnyPiiRead() {
        jdbc.page("old-cipher");
        var error=assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",OTHER,false,"已核验原始证件"));
        assertEquals(ErrorCode.CONFLICT,error.getCode());
        verifyNoInteractions(tx);
    }

    @ParameterizedTest @NullAndEmptySource @ValueSource(strings={"    ","核验过了","甲\n乙\n丙","😀😀😀😀"})
    void reviewReasonMustContainAtLeastFiveCodePoints(String reason) {
        jdbc.page("old-cipher");
        assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",OTHER,true,reason));
        verifyNoInteractions(tx);
    }

    @Test void validDifferentPeopleMayHaveTheSameName() {
        assertTrue(IdCardUtil.isValid(EXISTING)); assertTrue(IdCardUtil.isValid(OTHER));
        jdbc.page("old-cipher"); when(tx.tryDecrypt("old-cipher")).thenReturn(Optional.of(EXISTING));
        assertDoesNotThrow(()->policy.requireNewIdentity("  同名  ","身份证",OTHER,true,"已核验不同人员原始证件"));
        assertEquals("  同名  ",jdbc.names.getFirst());
    }

    @Test void sameDocumentCannotBeApprovedAsADifferentPerson() {
        jdbc.page("old-cipher"); when(tx.tryDecrypt("old-cipher")).thenReturn(Optional.of(" １１０１０５１９４９１２３１００２ｘ "));
        var error=assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",EXISTING,true,"已核验不同人员原始证件"));
        assertFalse(error.getMessage().contains(EXISTING));
        assertFalse(error.getMessage().contains("old-cipher"));
    }

    @ParameterizedTest @NullAndEmptySource @ValueSource(strings={"invalid","110105194912310021"})
    void invalidNewDocumentCannotUseTheSameNameException(String document) {
        jdbc.page("old-cipher");
        assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",document,true,"已核验不同人员原始证件"));
        verifyNoInteractions(tx);
    }

    @Test void anotherDocumentTypeCannotClaimResidentIdentityReview() {
        jdbc.page("old-cipher");
        assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","护照",OTHER,true,"已核验不同人员原始证件"));
        verifyNoInteractions(tx);
    }

    @Test void unreadableOrMissingExistingEvidencePreventsANewSameNameIdentity() {
        jdbc.page("missing-or-unreadable"); when(tx.tryDecrypt("missing-or-unreadable")).thenReturn(Optional.empty());
        var error=assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",OTHER,true,"已核验不同人员原始证件"));
        assertFalse(error.getMessage().contains("missing-or-unreadable"));
    }

    @Test void everySameNameCanonicalMustHaveValidDifferentEvidence() {
        jdbc.page("valid-cipher","old-invalid");
        when(tx.tryDecrypt("valid-cipher")).thenReturn(Optional.of(EXISTING));
        when(tx.tryDecrypt("old-invalid")).thenReturn(Optional.of("MASKED-DOCUMENT"));
        assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",OTHER,true,"已核验不同人员原始证件"));
    }

    @Test void boundedPagesDoNotSkipALaterSameDocument() {
        String[] first=new String[100]; java.util.Arrays.fill(first,"valid-cipher");
        jdbc.page(first); jdbc.page("same-document");
        when(tx.tryDecrypt("valid-cipher")).thenReturn(Optional.of(EXISTING));
        when(tx.tryDecrypt("same-document")).thenReturn(Optional.of(OTHER));
        assertThrows(ApiException.class,()->policy.requireNewIdentity("同名","身份证",OTHER,true,"已核验不同人员原始证件"));
        assertEquals(2,jdbc.names.size());
    }

    private static class FakeJdbc extends JdbcTemplate {
        int locks; int nextIdentity=1; final List<String> names=new ArrayList<>();
        final ArrayDeque<String[]> pages=new ArrayDeque<>();
        void page(String... ciphers){pages.add(ciphers);}
        @Override public <T> T queryForObject(String sql,Class<T> type,Object... args){locks++;return null;}
        @Override public <T> List<T> query(String sql,RowMapper<T> mapper,Object... args) {
            names.add((String)args[0]);
            if(pages.isEmpty())return List.of();
            List<T> rows=new ArrayList<>(); int index=0;
            for(String cipher:pages.removeFirst()) {
                ResultSet result=mock(ResultSet.class);
                try {
                    when(result.getObject(1,UUID.class)).thenReturn(new UUID(0,nextIdentity++));
                    when(result.getString(2)).thenReturn(cipher);
                    rows.add(mapper.mapRow(result,index++));
                } catch(SQLException failure){throw new AssertionError(failure);}
            }
            return rows;
        }
    }
}
