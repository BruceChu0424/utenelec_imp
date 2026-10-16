package com.uten.imp.common.util;

import jakarta.persistence.criteria.CriteriaBuilder;
import jakarta.persistence.criteria.Expression;
import jakarta.persistence.criteria.Predicate;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

class KeywordSearchTest {
    @Test
    void wordsHandleChineseWhitespaceCaseAndRepeatedInput() {
        assertEquals(List.of("螺丝", "m3", "不锈钢"), KeywordSearch.terms(" 螺丝\u3000M3\t不锈钢 螺丝 "));
        assertEquals(List.of(), KeywordSearch.terms(null));
        assertEquals(List.of(), KeywordSearch.terms("\u3000 \t"));
        assertEquals(List.of(), KeywordSearch.terms("\u00a0"));
    }

    @Test
    void percentUnderscoreAndBackslashAreLiteralCharacters() {
        assertEquals("%m3\\_20\\%\\\\a%", KeywordSearch.containsPattern("m3_20%\\a"));
    }

    @Test
    void localWordsAreLiteralAcrossFieldsAndNamesLeadIdentityMatches() {
        assertEquals(true, KeywordSearch.matches("螺丝 M3_20%", "不锈钢螺丝", "M3_20%"));
        assertEquals(false, KeywordSearch.matches("螺丝 M3_20%", "不锈钢螺丝", "M3X20A"));
        assertEquals(0, KeywordSearch.rankValue("Metric Screw", "Metric Screw", "OTHER"));
        assertEquals(1, KeywordSearch.rankValue("Metric Screw", "Metric Screw long", "OTHER"));
        assertEquals(2, KeywordSearch.rankValue("Metric Screw", "Small Metric Screw", "OTHER"));
        assertEquals(3, KeywordSearch.rankValue("Metric Screw", "Metric steel Screw", "OTHER"));
        assertEquals(4, KeywordSearch.rankValue("Metric Screw", "ordinary", "Metric Screw"));
    }

    @Test
    @SuppressWarnings("unchecked")
    void wordsAreAndedWhileFieldsAreOredWithExplicitLiteralEscaping() {
        CriteriaBuilder cb = mock(CriteriaBuilder.class);
        Expression<String> name = mock(Expression.class);
        Expression<String> model = mock(Expression.class);
        Expression<String> lowerName = mock(Expression.class);
        Expression<String> lowerModel = mock(Expression.class);
        when(cb.lower(name)).thenReturn(lowerName);
        when(cb.lower(model)).thenReturn(lowerModel);
        Predicate nameScrew = mock(Predicate.class);
        Predicate modelScrew = mock(Predicate.class);
        Predicate nameM3 = mock(Predicate.class);
        Predicate modelM3 = mock(Predicate.class);
        when(cb.like(lowerName, "%螺丝%", '\\')).thenReturn(nameScrew);
        when(cb.like(lowerModel, "%螺丝%", '\\')).thenReturn(modelScrew);
        when(cb.like(lowerName, "%m3\\_20\\%%", '\\')).thenReturn(nameM3);
        when(cb.like(lowerModel, "%m3\\_20\\%%", '\\')).thenReturn(modelM3);
        Predicate screw = mock(Predicate.class);
        Predicate m3 = mock(Predicate.class);
        Predicate all = mock(Predicate.class);
        when(cb.or(new Predicate[]{nameScrew, modelScrew})).thenReturn(screw);
        when(cb.or(new Predicate[]{nameM3, modelM3})).thenReturn(m3);
        when(cb.and(new Predicate[]{screw, m3})).thenReturn(all);

        assertEquals(all, KeywordSearch.allTerms(cb, "螺丝 M3_20%", name, model));

        verify(cb).and(new Predicate[]{screw, m3});
        verify(cb).or(new Predicate[]{nameScrew, modelScrew});
        verify(cb).or(new Predicate[]{nameM3, modelM3});
    }
}
