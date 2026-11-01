package com.uten.imp.features.rbac;

import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.IOException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** One reviewed plain-language catalog for central, personal and page permission settings. */
public final class PermissionBusinessDescriptions {
    public record Help(String code, String name, String description) { }
    private record Catalog(int schemaVersion, List<Help> permissions) { }
    private static final Map<String, Help> HELP = load();

    private PermissionBusinessDescriptions() { }

    public static String nameFor(String code, String catalogName) {
        Help help=code==null?null:HELP.get(code);
        return help==null?catalogName:help.name();
    }

    public static String descriptionFor(Permission permission) {
        return descriptionFor(permission.getCode(),permission.getDescription());
    }

    /** Presentation only: never adds, removes or infers any effective authority. */
    public static String descriptionFor(String code, String catalogDescription) {
        Help help=code==null?null:HELP.get(code);
        return help==null?catalogDescription:help.description();
    }

    public static Map<String, Help> catalog() { return HELP; }

    private static Map<String, Help> load() {
        try(var input=PermissionBusinessDescriptions.class.getResourceAsStream("/permission-help.json")) {
            if(input==null) throw new IllegalStateException("Permission help catalog is missing");
            Catalog catalog=new ObjectMapper().readValue(input,Catalog.class);
            if(catalog.schemaVersion()!=1) throw new IllegalStateException("Unsupported permission help schema");
            Map<String,Help> result=new LinkedHashMap<>();
            for(Help help:catalog.permissions()) {
                if(help.code()==null || help.name()==null || help.name().isBlank()
                        || help.description()==null || !help.description().contains("例如：")
                        || result.putIfAbsent(help.code(),help)!=null) {
                    throw new IllegalStateException("Invalid or duplicate permission explanation");
                }
            }
            return Map.copyOf(result);
        } catch(IOException failure) { throw new IllegalStateException("Cannot read permission explanations",failure); }
    }
}
