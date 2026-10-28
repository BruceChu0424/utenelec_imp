package com.uten.imp.common.util;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.Map;

/** Native-query counterpart of JpaColumnSearch, using owning-feature SQL expressions only. */
public final class SqlColumnSearch {
    private SqlColumnSearch() { }
    public record Field(String expression, JpaColumnSearch.Kind kind) {
        public static Field text(String expression) { return new Field(expression, JpaColumnSearch.Kind.TEXT); }
        public static Field decimal(String expression) { return new Field(expression, JpaColumnSearch.Kind.DECIMAL); }
        public static Field instant(String expression) { return new Field(expression, JpaColumnSearch.Kind.INSTANT); }
        public static Field calendarDate(String expression) { return new Field(expression, JpaColumnSearch.Kind.DATE); }
    }
    public record Criteria(String predicate, Map<String, Object> parameters) {
        public void bind(jakarta.persistence.Query query) { parameters.forEach(query::setParameter); }
    }
    public static Criteria criteria(Map<String, String> input, Map<String, Field> fields) {
        return criteria(input, fields, "column_");
    }
    /** A trusted feature namespace lets independent predicates share one native query. */
    public static Criteria criteria(Map<String, String> input, Map<String, Field> fields, String parameterPrefix) {
        if (parameterPrefix == null || !parameterPrefix.matches("[A-Za-z][A-Za-z0-9_]*"))
            throw new IllegalArgumentException("Invalid column parameter namespace");
        var values = ColumnKeywordSearch.validate(input, fields.keySet());
        var predicates = new ArrayList<String>();
        Map<String, Object> parameters = new LinkedHashMap<>();
        values.forEach((key, value) -> {
            Field field = fields.get(key);
            String parameter = parameterPrefix + parameters.size();
            switch (field.kind()) {
                case TEXT -> {
                    for (String term : KeywordSearch.terms(value)) {
                        String termParameter = parameterPrefix + parameters.size();
                        predicates.add("lower(coalesce(" + field.expression() + ",'')) LIKE :" + termParameter + " ESCAPE '\\'");
                        parameters.put(termParameter, NameRefKeyword.like(term));
                    }
                }
                case DECIMAL -> {
                    var parsed = NumericColumnFilter.parse(value);
                    predicates.add(parsed.sql(field.expression(), parameter));
                    parsed.bind(parameter, parameters::put);
                }
                case INSTANT -> {
                    var bounds = JpaColumnSearch.businessDateBounds(value);
                    predicates.add(field.expression() + " >= :" + parameter + "_from AND "
                            + field.expression() + " < :" + parameter + "_to");
                    parameters.put(parameter + "_from", bounds.from());
                    parameters.put(parameter + "_to", bounds.toExclusive());
                }
                case DATE -> {
                    var bounds = JpaColumnSearch.businessDateBounds(value);
                    predicates.add(field.expression() + " >= :" + parameter + "_from AND "
                            + field.expression() + " < :" + parameter + "_to");
                    parameters.put(parameter + "_from", bounds.from().toLocalDate());
                    parameters.put(parameter + "_to", bounds.toExclusive().toLocalDate());
                }
            }
        });
        return new Criteria(predicates.isEmpty() ? "TRUE" : String.join(" AND ", predicates), Map.copyOf(parameters));
    }
}
