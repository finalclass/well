# Release well framework

Use when the user asks to release, bump version, or tag a new version of well.

## Procedure

1. Determine new version (ask user or infer from changes: patch/minor/major)
2. Bump version in `lib/well/well.ml` → `let version = "X.Y.Z"`
3. Bump version in `dune-project` → `(version X.Y.Z)`
4. Add changelog entry to `CHANGELOG.md` (newest first, include date, summarize commits since last tag)
5. Commit: `Bump version to X.Y.Z`
6. Tag: `git tag vX.Y.Z`
7. Push: `git push && git push --tags`

## Version sources

- **well framework**: `lib/well/well.ml` + `dune-project` — must match, synced with git tags
- **Scaffolded projects**: `dune-project` `(version 0.0.1)` — independent, user bumps themselves

## Changelog format

```markdown
## vX.Y.Z — YYYY-MM-DD

### New features
- ...

### Improvements
- ...

### Fixes
- ...
```

## Notes

- Current version is read from latest git tag: `git tag --list 'v*' --sort=-v:refname | head -1`
- `well release` CLI reads version from project's `dune-project` to name the archive `<name>-v<version>.tar.gz`
- Always move the tag to the final commit (after changelog) if needed: `git tag -d vX.Y.Z && git tag vX.Y.Z`
