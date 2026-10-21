# Movie Night

Paste text, get a short link. See `docs/SPEC.md` for the full spec.

## Development

### Prerequisites

Install the Haskell toolchain with [ghcup](https://www.haskell.org/ghcup/),
including Stack. The project is pinned to the Stackage snapshot in
`stack.yaml` (LTS 24.64, GHC 9.10.3); Stack installs that GHC via ghcup if
it is missing.

### Build and run

```
stack build                 # build library, executable, and tests
stack exec movie-night      # run the executable
```

### Tests

```
stack test                              # build and run the full test suite
stack test --file-watch                 # re-run tests whenever a file changes
stack test --ta '--match "FR-8"'        # run only tests whose description matches
```

`--ta` passes arguments through to hspec. Test descriptions include
requirement IDs from the spec (e.g. `FR-17`), so `--match "FR-17"` runs the
tests for one requirement.

CI runs `stack test` on a native ARM64 runner for every push to `main` and
every pull request (`.github/workflows/ci.yml`).
