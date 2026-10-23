# CLAUDE.md

Movie Night is a paste-and-short-link web app (Haskell + Servant). "Movie
Night" is the application's name. The spec is in `docs/SPEC.md`.

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

## Line length in all files

The user's editor hard-wraps every file at 76 columns, code included. It
usually wraps code safely, but it once joined two Haskell statements into
a broken line. So:

- Keep lines you write or change within 76 columns in every file, so the
  editor has nothing to reflow. Leave untouched long lines alone.
- After the user has edited a file, build and test before relying on it,
  and suspect reflowed lines first if code that worked stops compiling.
