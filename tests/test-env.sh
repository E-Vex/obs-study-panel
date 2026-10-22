#!/usr/bin/env bash
#
# tests/test-env.sh - optional environment for the multi-language test suite.
#
# Sourced (when present) by tests/test-port.sh. On the CI/dev box used to
# verify the ports, some toolchains live in /home/z/my-project/toolchains
# instead of system paths; users with system-wide installs don't need this.
#
if [ -d /home/z/my-project/toolchains ]; then
    TC=/home/z/my-project/toolchains
    [ -f "$TC/env.sh" ] && . "$TC/env.sh"
    # JVM helpers used by the Scala/Kotlin/Groovy ports' run templates
    SCALA_LIB="$TC/scala-2.13.16/lib/scala-library.jar"
    export SCALA_LIB
    if [ -d "$TC/dotnet" ]; then
        export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
        export DOTNET_CLI_HOME="$TC/dotnet-home"
    fi
fi
