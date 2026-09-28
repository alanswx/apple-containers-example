# Apple Containers: cross + Quartus

Build MiSTer-style software and FPGA cores on an Apple silicon Mac using
Apple's [`container`](https://github.com/apple/container) tool, with the same
Linux toolchains GitHub Actions uses:

- **Rust cross-compilation** to ARMv7 Linux (the MiSTer's CPU).
- **Quartus Prime Lite 17.0** running as amd64 Linux under Rosetta, for
  Cyclone V cores. A full MiSTer core (Apple IIgs) builds in about 11 minutes
  on an M4 Max, bit-identical to a native x86 Linux build.
- A **GitHub Actions** workflow that builds the same things with Docker.

Forked from
[NigelBreslaw/apple-containers-example](https://github.com/NigelBreslaw/apple-containers-example),
a small extraction of the container patterns used by MiSTer MagiK. This fork
adds fixes for building real cores under Rosetta and a script for building your
own Quartus projects.

## Requirements

- An Apple silicon Mac on a macOS version supported by Apple `container`, with
  Rosetta installed (`softwareupdate --install-rosetta`).
- Apple `container`: `brew install container`.
- For Quartus: about 15 GB of free disk (3.4 GB of installers, a 7.9 GB
  install, and container images), 16 GB or more of RAM for large cores, and
  the two Intel installer files (see
  [Getting the Quartus installers](#getting-the-quartus-installers)).

Start the container service once per boot (the first run downloads a Linux
kernel):

```sh
container system start --enable-kernel-install
```

Use `brew services start container` instead to start it at every login.

## Cross-compile Rust for MiSTer

```sh
scripts/cross-apple.sh
file target/armv7-unknown-linux-gnueabihf/release/apple-containers-example
# ELF 32-bit LSB pie executable, ARM, EABI5 ...
```

The builder image uses Ubuntu 20.04 so binaries stay compatible with the older
userspace on MiSTer. Cargo registry and Git caches are kept outside the
container in `~/.cache/apple-containers-example`, so rebuilds are fast.

## Quartus on Apple silicon

Download and use of Quartus is governed by Intel's license. Setting
`QUARTUS_ACCEPT_EULA=1` confirms that you have accepted the Quartus Prime Lite
terms.

### 1. Install Quartus (once, about 15 minutes)

```sh
QUARTUS_ACCEPT_EULA=1 scripts/quartus-apple.sh
# ... ends with: Version 17.0.0 Build 595 04/25/2017 SJ Lite Edition
```

This verifies the pinned SHA-1s of the installers, builds the amd64 runtime
image, and installs Quartus into the ignored `build/quartus` directory. Quartus
itself runs as amd64 under Rosetta, but its old installer hangs there, so a
small arm64 helper container installs it inside an amd64 Ubuntu 18.04 QEMU
chroot instead. No Intel software is redistributed.

### 2. Build the example project

```sh
scripts/quartus-build.sh apple
```

This compiles the minimal Cyclone V project in `fpga/` and writes
`fpga/output_files/example.rbf` plus `build-manifest.txt` (see
[Matching local and CI builds](#matching-local-and-ci-builds)). It refuses to
run on an uncommitted checkout, so the manifest always names a real commit.

### 3. Build your own core

`scripts/quartus-core-apple.sh` compiles any Quartus 17 project folder, such
as a MiSTer core checkout:

```sh
scripts/quartus-core-apple.sh ~/src/Apple-IIgs_MiSTer
# -> ~/src/Apple-IIgs_MiSTer/output_files/Apple-IIgs.rbf
```

It finds the single `.qpf` in the folder (or pass the project and revision
names as extra arguments), runs the project's `PRE_FLOW_SCRIPT_FILE` hook
(MiSTer's `build_id.tcl`), and then runs synthesis, fit, assembly and timing
analysis with the workarounds described below. Build output is written into
the project folder, as a normal Quartus build would.

| Variable | Default | Meaning |
|---|---|---|
| `QUARTUS_FIT_THREADS` | `8` | Fitter threads. Also changes placement; see below. |
| `QUARTUS_CPUS` | all host CPUs | CPUs given to the container VM. |
| `QUARTUS_MEMORY` | `16g` | Memory given to the container VM. |
| `QUARTUS_CACHE_DIR` | `build/quartus` | Where the installers and install live. |

### Getting the Quartus installers

Intel no longer serves the 17.0.0 files at their original URLs; they return
403. The scripts need:

| File | SHA-1 |
|---|---|
| `QuartusLiteSetup-17.0.0.595-linux.run` | `99ccfb15962febceba64de2dc9b28c47e5a3b8df` |
| `cyclonev-17.0.0.595.qdz` | `2198dedb99866f38d43ff6c029d4bd668e2bbb59` |

If you have them (for example from an older Quartus download's `components/`
folder), copy them into `build/quartus/` before running the setup script; it
skips the download and still checks the hashes. Otherwise set
`QUARTUS_17_0_RUN_URL` and `QUARTUS_17_0_CYCLONEV_QDZ_URL` to a mirror you
control. The GitHub workflow reads repository variables with the same names.

## Quartus under Rosetta

Two Quartus problems appear only with real cores (the tiny example does not
trigger them). Both scripts handle them. If you write your own commands, handle
them the same way.

**`quartus_sh --flow compile` hangs in Analysis & Synthesis.** `quartus_map`
starts RTL helper processes that talk to it over named pipes. Under Rosetta
the helpers block opening their pipes while the parent polls forever. It
happened on every attempt, whether the project was on the shared folder or on
the container's own disk, and `PARALLEL_SYNTHESIS OFF` does not stop the
helpers. Running `quartus_map --parallel=1` does. The scripts therefore run the
stages directly:

```sh
quartus_map --parallel=1 <project>
quartus_fit --parallel=8 <project>
quartus_asm <project>
quartus_sta <project>
```

Running the stages directly skips flow hooks, so run a `PRE_FLOW_SCRIPT_FILE`
yourself (`quartus_sh -t sys/build_id.tcl compile <project> <revision>` for
MiSTer cores). The exact cause inside Rosetta has not been identified.

**The fitter slows down sharply with many threads.** Fitter times for the
Apple IIgs core on an M4 Max:

| Fitter threads | Wall time | CPU time |
|---|---|---|
| 16 | 33:15 | 7 h 20 m |
| 8 | 7:19 | 22 m |
| 4 | 8:11 | 17.5 m |
| 1 | 14:58 | 15 m |

Full IIgs build with the stepwise flow and 8 fitter threads: 10:54 in the
Apple container, against 9:12 natively on a 12th-gen Core i9.

## Matching local and CI builds

Running the same `.qsf` with two installations called “Quartus 17” is not a
reproducibility contract. The local and CI lanes share and verify the inputs
that can change the output:

- Both run the exact amd64 Quartus 17.0.0 Build 595 payload with the same
  Cyclone V device package, checksum-pinned.
- Both use the same Ubuntu 18.04 runtime `Containerfile`. Apple runs that amd64
  image through Rosetta; GitHub runs it with Docker on Linux. The different
  installer path is only a workaround for the old installer, not a different
  synthesis runtime.
- Both call `scripts/quartus-build.sh`, which refuses a dirty checkout, checks
  the Quartus version, and runs the same stepwise flow.
- The project pins the device, fitter seed (`2`) and processor count (`4`),
  and disables parallel synthesis. **The processor count matters**: fitter
  placement depends on the thread count, so `NUM_PARALLEL_PROCESSORS ALL`
  produces different bits on a 16-core workstation and a 4-core runner. With
  the same thread count, the Apple container and a native x86 build produced
  byte-identical IIgs RBFs. For the same reason, set `QUARTUS_FIT_THREADS` to
  the same value everywhere you compare `quartus-core-apple.sh` output.
- Each build writes `output_files/build-manifest.txt` with the Git commit,
  tool, flow and settings identity, critical input hashes, and the final RBF
  hash. Compare this file between local and GitHub artifacts instead of
  trusting labels.

The production MagiK gate goes further: it snapshots the frozen candidate and
pinned upstream sources, uses one preparation script for local and CI, builds
matched stock/baseline/patched variants, and binds all reports and delta checks
into the signoff evidence. CI reconstructs the release result; a local pass is
development evidence, not production authority.

## GitHub Actions (Linux, not Apple)

Run **Actions → Container examples → Run workflow**. The workflow has two
independent Ubuntu jobs:

- `cross` builds the ARMv7 Rust binary with Docker and `cross`.
- `quartus` downloads the installers, builds the Docker runtime, and compiles
  the same frozen Cyclone V inputs through the shared build script. Because of
  the dead Intel URLs, it needs the `QUARTUS_17_0_RUN_URL` and
  `QUARTUS_17_0_CYCLONEV_QDZ_URL` repository variables pointing at a mirror.

The Quartus job is intentionally manual: the download and install are large
and require accepting Intel's terms. For a real project, cache the private
installed runtime in storage you control; do not publish it as a public image.

On a Linux machine with Docker, `QUARTUS_ACCEPT_EULA=1 scripts/quartus-docker.sh`
and `scripts/quartus-build.sh docker` run the same lane locally.

## Layout

```text
containers/cross/       ARMv7 compiler image used locally and in Actions
containers/quartus/     Quartus runtime and installer helper images
scripts/                Apple and Docker entry points
  cross-apple.sh          Rust cross-compile in an Apple container
  quartus-apple.sh        Install Quartus for Apple containers
  quartus-docker.sh       Install Quartus for Docker (Linux / CI)
  quartus-build.sh        Build the pinned example (apple|docker)
  quartus-core-apple.sh   Build any Quartus project in an Apple container
fpga/                   Minimal Cyclone V project
.github/workflows/      Two-job Linux workflow
```

The pins (Rust 1.98.0, Ubuntu 20.04, Quartus 17.0 Build 595, Cyclone V) mirror
the compatibility choices in MiSTer MagiK; update them deliberately.

Licensed under GPL-3.0-or-later. Quartus itself remains subject to Intel's
separate license and is not included in this repository.
