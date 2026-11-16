# Static analysis of the C sources

The daemon's adapter, the daemon, and the command-line client are
analysed by three tools, and the findings are compared with a baseline:
`baseline.txt` holds the findings that have been read and accepted, each
with the reason it is accepted.

    ./build_test.sh --analyze      the analysis on its own
    ./build_test.sh --gate 33      the same work, in the default run
    ./build_test.sh --analyze-cpp  the same for the MCP server's C++17 (mcp/src)

The three tools read the same sources and share nothing, so they run at the
same time; the wall clock is the slowest one (clang-tidy, about 90 s), not the
sum. `cppcheck` is given `--max-configs=1`: checking every `#ifdef`
combination took four minutes and reported the same findings as one
configuration.

The C++ analysis (`--analyze-cpp`, baseline `baseline-cpp.txt`) runs
`clang-tidy` and `cppcheck` over `mcp/src`. `clang-tidy` over the C++ takes
about nine minutes on one core (the JSON library is heavy), so it is spread over
four processes (about two minutes) and is a mode, not a gate in the default run.

The reports the run produces are written to the run's artifact directory
(the path is printed at the end of the mode).

## The tools, and what each one is for

| tool | what it looks for | why |
| --- | --- | --- |
| `gcc -fanalyzer` | leaks and paths the compiler's own analysis can prove | the only one that follows a value through the whole file |
| `clang-tidy` | the analyzer's checks, plus `bugprone-*` and `cert-*` | the security-relevant C checks |
| `cppcheck` | portability and warning-level findings, over the whole tree | a second opinion, on the code clang-tidy does not read |

The check sets, and the checks that are switched off:

* `-clang-analyzer-security.insecureAPI.DeprecatedOrUnsafeBufferHandling`
  -- it asks for the C11 `*_s` functions, which do not exist in glibc.
  `snprintf` and `memcpy` are the bounded functions in C.
* `-bugprone-easily-swappable-parameters` -- a readability check about
  parameters of the same type; it fires on almost every function with two
  size_t arguments.
* `-cert-err33-c` -- "the value returned by this function should be
  used". It fires on every `snprintf` whose result the code does not
  check, which is most of them: the code checks the sizes itself.

The version of each tool is printed by the run, because a different
version can report different findings -- and a different version is a
reason to read the new findings, not to accept them unread.

## The baseline

One line per (tool, file, check):

    tool | file | check | count | the reason it is accepted

The count is how many findings of that kind are accepted, so a finding
that moves a line does not break the comparison, and one that appears or
disappears does. A finding that is not in the baseline fails the run; so
does a baseline line that no longer matches what the tool reports (the
finding was fixed, and the line belongs in the history, or the tool's
wording changed and the line needs rewriting).

To write the baseline for a new tool or a new check set:

    python3 tests/analysis/compare.py --update tests/analysis/baseline.txt \
        ARTIFACT_DIR/gcc-fanalyzer.txt ARTIFACT_DIR/clang-tidy.txt ARTIFACT_DIR/cppcheck.txt

That writes the skeleton; every line then needs its reason, read from the
code at that place. "Too many to look at" is not a reason.
