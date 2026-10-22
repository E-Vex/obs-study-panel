#!/usr/bin/env bash
#
# tests/test-env.sh - optional environment for the multi-language test suite.
#
# Sourced (when present) by tests/test-port.sh. On the CI/dev box used to
# verify the ports, some toolchains live in /home/z/my-project/toolchains
# instead of system paths; users with system-wide installs don't need this.
#
TC=/home/z/my-project/toolchains
if [ -d "$TC" ]; then
    [ -f "$TC/env.sh" ] && . "$TC/env.sh"
    export JAVA_HOME="$TC/jdk"
    # rustup shim needs its home when the toolchain was installed there
    export RUSTUP_HOME="$TC/rustup"
    export CARGO_HOME="$TC/cargo"
    # TypeScript: point tsc at the locally installed @types/node when present
    if [ -d "$TC/node_modules/@types" ]; then
        TSC_FLAGS="--typeRoots $TC/node_modules/@types --types node"
        export TSC_FLAGS
    fi
    if [ -d "$TC/dotnet" ]; then
        export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
        export DOTNET_CLI_HOME="$TC/dotnet-home"
    fi
    # OCaml (ocamlopt needs the toolchain's lib dir on path)
    [ -d "$TC/ocaml" ] && export CAML_LD_LIBRARY_PATH="$TC/ocaml/lib/ocaml/stublibs"
fi
