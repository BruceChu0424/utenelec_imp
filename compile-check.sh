#!/usr/bin/env bash
# Compile all server sources with javac + Lombok, classpath from ~/.m2
set -e
export PATH="$PATH:/c/Windows/System32/WindowsPowerShell/v1.0:/c/Windows/System32"
export JAVA_HOME="C:\Program Files\Microsoft\jdk-21.0.11.10-hotspot"
cd /d/Projects/uten_imp/server
M2="/c/Users/bruce/.m2/repository"
LOMBOK="$M2/org/projectlombok/lombok/1.18.34/lombok-1.18.34.jar"
CP=$(find "$M2" -name '*.jar' -exec cygpath -w {} \; | tr '\n' ';')
rm -rf /tmp/uten-classes && mkdir -p /tmp/uten-classes
find src/main/java -name '*.java' > /tmp/uten-sources.txt
COUNT=$(wc -l < /tmp/uten-sources.txt)
echo "Compiling $COUNT files..."
"$JAVA_HOME/bin/javac" -encoding UTF-8 -nowarn -proc:full \
  -cp "$CP" -processorpath "$(cygpath -w "$LOMBOK")" \
  -d /tmp/uten-classes @/tmp/uten-sources.txt 2>&1 | head -100
echo "EXIT_OK"
