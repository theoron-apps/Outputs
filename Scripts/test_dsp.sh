#!/bin/zsh
set -e
cd "${0:A:h:h}"
clang -std=c11 -O2 -Wall -Wextra -Werror "$@" -framework CoreAudio Outputs/DSP/OutputsDSP.c Tests/DSPTests.c -o "${TMPDIR:-/tmp}/outputs-dsp-tests"
"${TMPDIR:-/tmp}/outputs-dsp-tests"
