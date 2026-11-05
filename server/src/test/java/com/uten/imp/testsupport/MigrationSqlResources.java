package com.uten.imp.testsupport;

import org.springframework.core.io.ClassPathResource;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.regex.Pattern;

/** Loads the actual retained migration routines for isolated PostgreSQL contract fixtures. */
public final class MigrationSqlResources {
    private MigrationSqlResources() { }

    public static String read(String name) throws IOException {
        return new ClassPathResource("db/migration/" + name).getContentAsString(StandardCharsets.UTF_8);
    }

    public static String function(String source, String name) {
        var start = Pattern.compile("(?im)^\\s*CREATE(?:\\s+OR\\s+REPLACE)?\\s+FUNCTION\\s+(?:public\\.)?"
                + Pattern.quote(name) + "\\s*\\(").matcher(source);
        if (!start.find()) throw new IllegalArgumentException("Missing original function " + name);
        String tail = source.substring(start.start());
        var body = Pattern.compile("(?is)\\bAS\\s+(\\$[a-zA-Z0-9_]*\\$)").matcher(tail);
        if (!body.find()) throw new IllegalArgumentException("Missing original function body " + name);
        int end = tail.indexOf(body.group(1), body.end());
        if (end < 0) throw new IllegalArgumentException("Unclosed original function " + name);
        end = tail.indexOf(';', end + body.group(1).length());
        if (end < 0) throw new IllegalArgumentException("Unterminated original function " + name);
        return tail.substring(0, end + 1);
    }
}
