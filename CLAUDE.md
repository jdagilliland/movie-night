# CLAUDE.md

This repo hosts a paste-and-short-link web app (Haskell + Servant), despite the
repo name. The spec is in `docs/SPEC.md`.

## Git

The user operates git. Do not run git commands that change repository state
(commit, branch, merge, rebase, push, stash, reset, tag). Read-only commands
(status, diff, log, show) are fine for understanding the current state.
Don't offer to commit; just report what changed.

## Markdown

Hard-wrap Markdown prose at around 76 characters. Only re-wrap lines whose
content you are changing; leave the wrapping of untouched lines alone, even
if they are longer or shorter than 76 characters, to keep git diffs free of
wrapping noise. Tables, code blocks, and URLs are exempt from wrapping.
