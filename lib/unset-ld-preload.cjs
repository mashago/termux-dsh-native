// termux-dsh-native: drop loader variables before spawning child processes.
//
// The dsh Node process runs with the glibc link shim in LD_PRELOAD. Bionic
// children (bash, coreutils, pnpm's spawned npm) cannot load a glibc .so, so
// the preload must not cross an exec boundary. The shim also unsets it; this
// preload covers callers that set LD_PRELOAD again after the shim loads.
delete process.env.LD_PRELOAD
delete process.env.LD_LIBRARY_PATH
delete process.env.LD_AUDIT
