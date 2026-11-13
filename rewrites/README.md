# Versioned text rewrites

The Android/Termux install needs two small text rewrites inside dsh's compiled
`lib/` files. dsh is pre-stable, so each dsh version gets its own rewrite set;
the dispatcher picks the set by the installed version and fails loudly when none
matches.

```
rewrites/
├── apply-rewrites.sh             # launcher: runs the glibc Node on the dispatcher
├── apply-rewrites.mjs            # dispatcher: version -> set -> runner
├── lib/common.mjs                # backups, atomic writes, syntax check, marker handling
└── sets/
    └── <set-id>/
        ├── manifest.json         # { versions, default?, extends?, notes? }
        ├── index.mjs             # export const rewrites = [...]
        └── NOTES.md              # anchors and verification record
```

## Adding a dsh version

1. Install the new dsh version (service stopped, `--ignore-scripts`).
2. Trial the existing set against it:
   `DSH_REWRITE_FALLBACK=1 bash apply-rewrites.sh --dry-run`
   (or `--set <set-id>` to force one).
3. **Anchors still match** → add an alias set, no code copied:

   ```sh
   mkdir sets/<new-version>
   cat > sets/<new-version>/manifest.json <<'EOF'
   { "versions": ["<new-version>"], "extends": "<existing-set-id>" }
   EOF
   ```

4. **Anchors drifted** → copy the closest set, change `versions`, drop
   `extends`, and adjust the anchors in `index.mjs` until `--dry-run` reports
   `would rewrite` for every rewrite.
5. Apply for real, then verify and smoke-test:

   ```sh
   bash apply-rewrites.sh
   bash ../verify-install.sh
   ```

`--check-only` verifies markers without writing (used by `verify-install.sh`);
`--show-set` prints the selected set. `DSH_EXPECTED_VERSION` is an optional
assertion; unknown versions fail unless `DSH_REWRITE_FALLBACK=1` is set.

A successful apply writes `$DSH_ROOT/rewrites-state.json` with the installed
version, the selected set, and the extends chain; `--check-only` warns when that
state belongs to a different version or set.