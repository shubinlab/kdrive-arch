# kDrive Arch installation and telemetry log

This is the durable, redacted protocol for installs and updates on Arch,
CachyOS, and Omarchy hosts. It records facts, errors, and follow-up tests;
passwords, tokens, raw journals, host identifiers, and full core dumps do not
belong here.

## Protocol

For every update:

1. Save a mode-`0600` pre-update snapshot under
   `~/.local/state/kdrive-arch/telemetry/`.
2. Record the package version, legacy-package presence, user-unit owner,
   active/enabled state, main executable, restart count, exit status, recent
   journal summary, and coredump count.
3. Run the universal installer from the latest release:

   ```bash
   curl -fL https://github.com/shubinlab/kdrive-arch/releases/latest/download/install.sh | bash
   ```

4. Save a post-update snapshot, then verify the package owner, unit path,
   executable path, `Connected to server`, restart count, exit status, and
   absence of a new kDrive coredump.
5. If installation fails, preserve the installer error and verify that the
   previous package and service state were restored before retrying.

## Future issue classification

- `AUTH-BLOCKED`: sudo/polkit cannot obtain an interactive authorization; do
  not classify this as a package or kDrive failure.
- `INSTALL-FAILED`: installer exits after mutation; require rollback and a
  matching error/journal entry.
- `RUNTIME-FAILED`: package installs but unit is inactive, restarts, exits
  non-zero, points outside `/opt/kdrive-arch`, or produces a new coredump.
- `UPSTREAM-WARNING`: service reaches `Connected to server` but emits a
  non-fatal vendor warning; report separately from a crash.

Host-specific entries and telemetry snapshots stay local under
`~/.local/state/kdrive-arch/telemetry/` with mode `0600`; do not commit them
to this repository.
