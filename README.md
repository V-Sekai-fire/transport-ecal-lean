# transport-ecal-lean

Eclipse eCAL shared-memory publish and subscribe from Lean 4, writing and reading each message in place.

## What it is for

It replaces iceoryx2 as the zero-copy link between local processes, including 3840x2160 RGBA frames from Godot to interactor-cineform. `EcalLean.lean` is the Lean API; `ffi/ecal_lean.c` binds eCAL's C API. A publisher's closure writes the message straight into eCAL's memory file, and a subscriber's closure reads it there; the subscriber's view is cleared when its closure returns. `tests/run.sh` runs a subscriber and a publisher as two processes: varied-size messages with checksums, two planted defects (a dropped message, a changed byte) that must fail, 4K frames, and the same frames through a pipe for comparison.

On macOS 26 with eCAL 6.1.1 the two processes do not find each other: UDP registration finds no peer, and shared-memory registration fails with `ftruncate failed ... /ecal_mon errno: Invalid argument` and `flock: Operation not supported`. eCAL's own README marks macOS as experimental. `tests/linux.sh` runs the checks in an Ubuntu 24.04 container.

## Build and run

```sh
./scripts/build-ecal.sh   # eCAL v6.1.1 core and C binding, in .ecal/
lake build
./tests/run.sh            # N=messages FRAMES=frames
./tests/linux.sh          # the same, in a Linux container (podman)
```

## Licence

MIT; see `LICENSE`. eCAL is Apache-2.0.
