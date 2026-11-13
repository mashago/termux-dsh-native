# Step 0 link shim spike — results (2026-11-13)

Device: iQOO / Android 16 / aarch64; Termux glibc 2.44; Node 24.19.0 official linux-arm64.

Build method (validated):

1. Copy the device's glibc headers to `.build-sysroot/include`.
2. Mac `clang --target=aarch64-linux-gnu` compiles `shim/link_shim.c` to `link_shim.o`.
3. Device `env -u LD_PRELOAD $PREFIX/glibc/bin/ld -shared` links
   `libdsh-termux-native-link.so` against the device's own glibc.

No cross toolchain was installed; `clang + device glibc ld` was used.

## Results

Control (no shim, `SPIKE_EXPECT=fail`):

```
PASS plain link is denied without the shim   (EACCES)
```

Shim run (9 checks, all pass):

```
PASS link succeeds with the shim
PASS target is a copy, not a hard link
PASS content and mode are preserved
PASS existing target yields EEXIST
PASS directory source yields EPERM
PASS symlink source remains a symlink
PASS concurrent link yields one success and one EEXIST
INFO large=50MB elapsed_ms=143.7
PASS large file copy
PASS bionic child starts without LD_PRELOAD
SUMMARY checks=9 failures=0
```

Observed shim log:

```
dsh-link-shim: loaded (real_link=0x...)
ld_preload=null
dsh-link-shim: link(..., target) denied (13); fallback copy
dsh-link-shim: link(..., target) published copy
...
```

ELF facts:

```
NEEDED  libc.so.6
SONAME  libdsh-termux-native-link.so
INIT_ARRAY present
GLIBC_2.17, GLIBC_2.33, GLIBC_2.34
```

## Conclusion

The LD_PRELOAD interposition works for Node/libuv `fs.link`/`fs.linkSync`;
the copy fallback preserves source, mode and content; EEXIST/no-clobber,
directory EPERM, symlink copy, concurrency, and bionic-child isolation all
behave as designed. The shim foundation is verified; proceed to the dsh
installation steps.

The device-side spike directory was temporary and is removed after the
installation step reuses the downloaded Node tree.