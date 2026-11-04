package com.uten.imp.testsupport;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.nio.file.*;
import java.util.*;

/** One repository-owned example contract for Java, SQL, Flutter and candidate clients. */
public final class BusinessPrecisionContractCases {
    private BusinessPrecisionContractCases(){ }
    public static List<JsonNode> load(){
        Path directory=Path.of(System.getProperty("user.dir")).toAbsolutePath();
        try{
            while(directory!=null){
                Path source=directory.resolve("contracts/business-precision/v1.json");
                if(Files.isRegularFile(source)){
                    var contract=new ObjectMapper().readTree(source.toFile());
                    if(contract.path("version").asInt()!=1||!contract.path("cases").isArray())throw new IllegalStateException("Business precision contract version missing");
                    var cases=new ArrayList<JsonNode>();contract.path("cases").forEach(cases::add);return List.copyOf(cases);
                }
                directory=directory.getParent();
            }
            throw new IllegalStateException("Repository business precision contract missing");
        }catch(java.io.IOException failure){throw new IllegalStateException("Cannot read business precision contract",failure);}
    }
}
