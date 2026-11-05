package com.uten.imp.common.finance;
import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.*;
import java.io.IOException;
/** Exact raw financial request trees, before an untyped double can be created. */
public final class FinancialJsonNodeDeserializer extends JsonDeserializer<JsonNode> {
    @Override public JsonNode deserialize(JsonParser parser,DeserializationContext context)throws IOException{
        if(!(parser.getCodec() instanceof ObjectMapper mapper))throw JsonMappingException.from(parser,"金融原体需要当前已配置的JSON读取器");
        return FinancialJsonResults.reader(mapper).readTree(parser);
    }
}
