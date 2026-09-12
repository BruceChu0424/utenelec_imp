package com.uten.imp.migration;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;
import java.util.Random;

/** Synthetic inputs only; expected classifications always come from actual V555 generated columns. */
final class AuditClassificationCases {
    private AuditClassificationCases() {}

    static List<Object[]> create() {
        String[] keywords = {"refresh_reuse","reuse_detected","delete","http_delete","http_get","permission","authorization",
                "data-scope","data_scope","data-scopes","data_scopes","system-setting","system_setting","system-settings","system_settings",
                "reset-password","balance-adjust","blacklist","/reverse","/offboard","failure","failed","denied","bad_","not_found",
                "locked","disabled","rate_limited","invalid","expired","login_failed","change_password","verify_password","export_",
                "/export","reuse","access_denied","role","login","logout","password","refresh_token","auth/","user_preferences"};
        List<Object[]> rows = new ArrayList<>();
        String[] emptyCases = {null,"","INSERT","http_get"};
        for (int i = 0; i < 1024; i++) {
            Object[] row = base();
            int combination = i;
            for (int field = 0; field < 5; field++) {
                row[field] = emptyCases[combination % 4];
                combination /= 4;
            }
            rows.add(row);
        }
        for (String keyword : keywords) {
            List<String> variants = List.of(keyword, keyword.toUpperCase(Locale.ROOT),
                    keyword.substring(0,1).toUpperCase(Locale.ROOT)+keyword.substring(1), "pre"+keyword+"post", " "+keyword+" ",
                    keyword+"s", keyword.substring(0,keyword.length()-1), keyword.replace('_','-'), keyword.replace('-','_'),
                    "中"+keyword+"😃", "İ"+keyword+"Σ", keyword.replace('_','＿').replace('-','—'),
                    keyword.substring(0,keyword.length()/2)+" "+keyword.substring(keyword.length()/2));
            for (int field = 0; field < 5; field++) {
                for (String variant : variants) {
                    for (Integer status : Arrays.asList(null,0,399,400,500)) {
                        Object[] row = base();
                        row[field] = variant;
                        row[5] = status;
                        rows.add(row);
                    }
                }
            }
        }
        for (String left : keywords) {
            for (String right : keywords) {
                for (int[] pair : new int[][]{{0,1},{2,4},{0,3}}) {
                    Object[] row = base();
                    row[pair[0]] = left;
                    row[pair[1]] = right;
                    rows.add(row);
                }
            }
        }
        for (String value : List.of("export","exportX","export_","export\n","export😃","export＿","xexport_","x/export","EXPORTX","export%","/EXPORT",
                "data-scop","datascope","system-settingsx","systemsetting","roleplay","controlled","xauth/","auth","ACCESS_DENIED","UNLOCKED","not-found","BADX","prefiX_export_")) {
            for (int field = 0; field < 5; field++) {
                Object[] row = base();
                row[field] = value;
                rows.add(row);
            }
        }
        String[] noise = {"","é","e\u0301","İ","ı","Σ","σ","ς","中","🧪","𐐀","\n","\t"," ","\\","%","_","-","[","]","ordinary","a/b","UUID-"};
        Random random = new Random(20260912);
        Integer[] statuses = {null,-1,0,200,399,400,401,403,500,Integer.MAX_VALUE};
        for (int i = 0; i < 12000; i++) {
            Object[] row = base();
            for (int field = 0; field < 5; field++) {
                row[field] = random.nextInt(12) == 0 ? null : noise[random.nextInt(noise.length)]
                        + (random.nextBoolean() ? keywords[random.nextInt(keywords.length)] : noise[random.nextInt(noise.length)])
                        + noise[random.nextInt(noise.length)];
            }
            row[5] = statuses[random.nextInt(statuses.length)];
            rows.add(row);
        }
        return rows;
    }

    private static Object[] base() {
        return new Object[]{"ordinary","success","production_material_analysis_materials","/api/material","arbitrary-id",null};
    }
}
