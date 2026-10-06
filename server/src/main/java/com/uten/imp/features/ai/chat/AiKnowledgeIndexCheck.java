package com.uten.imp.features.ai.chat;

/**
 * ADR-153 revision: verifies that a built application jar can load the AI assistant's packaged design documents
 * through the executable jar's own class loader, without starting the application or touching a database:
 * <pre>
 * java -cp uten-imp-server.jar -Dloader.main=com.uten.imp.features.ai.chat.AiKnowledgeIndexCheck \
 *      org.springframework.boot.loader.launch.PropertiesLauncher
 * </pre>
 * Prints the document and chunk counts and the number of business glossary terms (0 when the glossary is not packaged:
 * everyday words are then not read in the documents' terms); exits with status 1 when nothing was loaded (the assistant
 * would then answer every rule question with "no description found"). The release check and ServerJarPackagingIT run it.
 */
public final class AiKnowledgeIndexCheck {
    private AiKnowledgeIndexCheck() {}

    public static void main(String[] args) {
        AiDocKnowledge.Summary summary = AiDocKnowledge.packagedSummary();
        System.out.println("AI knowledge index check: documents=" + summary.documents() + " chunks=" + summary.chunks()
                + " glossaryTerms=" + summary.glossaryTerms());
        if (summary.documents() == 0 || summary.chunks() == 0) System.exit(1);
    }
}
