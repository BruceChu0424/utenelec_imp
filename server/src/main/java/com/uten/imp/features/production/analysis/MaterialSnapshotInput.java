package com.uten.imp.features.production.analysis;

import com.fasterxml.jackson.core.JsonFactory;
import com.fasterxml.jackson.core.JsonGenerator;
import java.io.IOException;
import java.io.StringWriter;
import java.math.BigDecimal;
import java.math.BigInteger;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import java.util.UUID;
import java.util.function.Function;
import java.util.stream.Collectors;

/** Fixed, typed snapshot rows carried in one bounded PostgreSQL parameter. */
final class MaterialSnapshotInput {
    private static final JsonFactory JSON=new JsonFactory();
    private final List<String> columns;
    private final String definitions;

    MaterialSnapshotInput(String... definitions) {
        this.columns=Arrays.stream(definitions).map(definition->definition.substring(0,definition.indexOf(' '))).toList();
        this.definitions=String.join(", ",definitions)+", _position integer";
        if(columns.stream().distinct().count()!=columns.size())throw new IllegalArgumentException("Duplicate snapshot column");
    }

    List<String> columns() { return columns; }

    String recordset(String alias) {
        return "jsonb_to_recordset(CAST(:snapshots AS jsonb)) AS "+alias+"("+definitions+")";
    }

    String selection(String alias) {
        return columns.stream().map(column->alias+"."+column).collect(Collectors.joining(", "));
    }

    <T> String json(List<T> rows,Function<T,Object[]> values) {
        StringWriter output=new StringWriter();
        try(JsonGenerator json=JSON.createGenerator(output)) {
            json.writeStartArray();
            for(int position=0;position<rows.size();position++) {
                Object[] row=values.apply(rows.get(position));
                if(row.length!=columns.size())throw new IllegalArgumentException("Snapshot column/value count mismatch");
                json.writeStartObject();json.writeNumberField("_position",position);
                for(int index=0;index<row.length;index++) {
                    json.writeFieldName(columns.get(index));write(json,row[index]);
                }
                json.writeEndObject();
            }
            json.writeEndArray();
        } catch(IOException failure) { throw new IllegalStateException("Cannot encode typed material snapshot",failure); }
        return output.toString();
    }

    private static void write(JsonGenerator json,Object value)throws IOException {
        if(value==null)json.writeNull();
        else if(value instanceof BigDecimal number)json.writeNumber(number);
        else if(value instanceof BigInteger number)json.writeNumber(number);
        else if(value instanceof Integer number)json.writeNumber(number);
        else if(value instanceof Long number)json.writeNumber(number);
        else if(value instanceof Short number)json.writeNumber(number.intValue());
        else if(value instanceof Boolean flag)json.writeBoolean(flag);
        else if(value instanceof String text)json.writeString(text);
        else if(value instanceof UUID id)json.writeString(id.toString());
        else if(value instanceof LocalDate date)json.writeString(date.toString());
        else if(value instanceof java.sql.Date date)json.writeString(date.toLocalDate().toString());
        else throw new IllegalArgumentException("Unsupported material snapshot value type: "+value.getClass().getName());
    }
}
