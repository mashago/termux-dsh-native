# termux-dsh-native

Run DeepSeek Harness (`dsh`) natively in Termux with minimal patches: no proot, no Linux subsystem, no custom Node build, no libc replacement.

Two small versioned patches and one `LD_PRELOAD` shim are all it takes.

Verified with `@deepseek-ai/dsh@0.2.2-rc.3` on Android 16 / aarch64.

## How it works

- **Link shim** (`dist/libdsh-termux-native-link.so`). Android rejects `link()` in app-private storage with `EACCES`. The shim turns it into copy → `fsync` → `renameat2(RENAME_NOREPLACE)`, preserving dsh's atomic publishes, and unsets `LD_PRELOAD` for child processes.
- **Wrapper** (`bin/dsh-wrapper.sh`). Sets `TMPDIR`, exports the optional fixed token, loads the shim, and execs the patched Node.
- **Two versioned patches** (`rewrites/sets/`): one required, one optional.
  1. `syncDirectory()` treats the first unreadable ancestor as the durability boundary; without it every attachment fails on Android.
  2. `processLaunchToken()` prefers `DSH_WEB_TOKEN`, keeping the web URL stable.

  A set applies only to the dsh versions it declares and stops on anchor drift.

## Requirements and limitations

- **Termux on Android, aarch64 only.** The shim is an aarch64 glibc object for Termux's glibc runtime; other apps and non-Termux environments cannot load it.
- **Termux glibc 2.44** (`glibc-repo`, `glibc`, `glibc-runner`) plus `patchelf`. Node is the official linux-arm64 build with only its ELF interpreter patched.
- **No Landlock.** dsh's `workspace-write` sandbox fails closed, so the install pins `DSH_PERMISSION_MODE=danger-full-access`. dsh's file fence is off; the Android app sandbox (Termux UID) is the real boundary.
- **You open the browser.** The launch path is untouched: `dsh web --no-open`, then visit the token URL. Cookies keep upstream `SameSite=Strict`, which is correct for address-bar visits.
- **Only supported dsh versions.** Versions not covered by a rewrite set are refused before anything changes.
- **~3 GB free space** and network for the first `npm install` (~1.2 GB dependency tree).

## Install

### Prerequisites

```sh
pkg install -y glibc-repo glibc glibc-runner termux-services coreutils curl tar xz-utils
```

The git-clone route also needs:

```sh
pkg install -y git
```

The installer only checks these packages. If something is missing it stops and prints the exact command; it never changes system packages itself.

### From a GitHub release

```sh
curl -fsSL https://github.com/mashago/termux-dsh-native/releases/latest/download/install.sh \
  | bash -s -- -y
```

### From a git clone

```sh
git clone https://github.com/mashago/termux-dsh-native
cd termux-dsh-native
bash install.sh -y
```

Both routes run the same installer: verify prerequisites, install or pin Node and dsh, deploy the runtime, apply the matching rewrites, verify, and start `dsh-web`. Flags: `--dsh-version <v>`, `--root <path>`, `--no-start`, `--uninstall`.

Open the printed URL after install (or use `~/start_dsh.sh status` later). The first visit trades the token for a 30-day cookie; afterwards `http://127.0.0.1:3080/` works directly.

## Running the service

```sh
~/start_dsh.sh status     # service state, HTTP port, auto-start, URL
~/start_dsh.sh start      # start and enable auto-start on Termux login
~/start_dsh.sh stop       # stop and disable auto-start
~/start_dsh.sh restart
```

`dsh-web` is managed by termux-services. It does not return after a phone reboot unless Termux:Boot is installed; opening a Termux login shell starts it.

## Upgrade and rollback

### From a GitHub release

```sh
curl -fsSL https://github.com/mashago/termux-dsh-native/releases/latest/download/update.sh \
  | bash -s -- 0.2.2-rc.2 -y
```

### From a git clone

```sh
git pull
bash update.sh 0.2.2-rc.2 -y    # pin a version; omit it to use the release's tested version
bash update.sh --check          # installed vs. supported versions
bash update.sh --rollback -y    # restore the previous version from install-state.json
```

The updater validates the target against the packaged rewrite sets before stopping anything, backs up runtime files, upgrades Node when required, reinstalls dsh, reapplies rewrites, verifies, and restores the previous service state. Failures roll back.

## Layout

```
install.sh / update.sh        release/clone bootstraps
install-core.sh               install / update / rollback / check / uninstall
make-release.sh               build the release payload and SHA256SUMS
dist/                         prebuilt link shim
shim/                         link() interposer source, Makefile, device spike
rewrites/
  apply-rewrites.{sh,mjs}     version -> rewrite set dispatcher
  lib/common.mjs              backups, atomic writes, syntax checks, markers
  sets/<set>/                 manifest.json + index.mjs
bin/                          wrapper and BROWSER opener
start_dsh.sh / start_sshd.sh  service management and sshd startup
verify-install.sh             post-install checks
smoke-web.sh                  dsh web startup/HTTP smoke test
```

Runtime (`~/.local/opt/dsh`): `node/`, `work/` (npm prefix), `lib/` (shim), `bin/`, `tools/` (rewrites), `etc/web-token`, `backups/`, plus `VERSION`, `rewrites-state.json`, `install-state.json`. dsh data lives in `~/.dsh`.

## Notes

- Token: `~/.local/opt/dsh/etc/web-token` (mode 600). Replace it and restart `dsh-web` to rotate; cookies last 30 days.
- Back up `~/.dsh` before upgrades, excluding `~/.dsh/cache`.
- Never run `npm install` without `--ignore-scripts`; koffi tries to compile.
- `update.sh --backup-home` tars `~/.dsh` (minus cache) first.

## Development

- Shim: `cd shim && make fetch-sysroot && make && make device-link`, then copy the `.so` into `dist/`.
- New dsh version: see `rewrites/README.md`; a compatible version needs only `{"versions":["<v>"],"extends":"<existing-set>"}`.
- Release: `./make-release.sh --project v0.3.0 --tested-dsh 0.2.2-rc.2`, then attach `release/*` to a GitHub release.
- In the wrapper, bionic commands must run before `LD_PRELOAD` is set.

## Uninstall

```sh
bash install.sh --uninstall               # keeps ~/.dsh
bash install.sh --uninstall --purge-home  # also deletes sessions and credentials
```

## License

MIT