# RTL8168.R4D

`RTL8168.R4D` is an independent R4OS driver implemented in Zig.

## Package

- Version: `0.1.4`
- Image target: `/R4OS/DRIVERS/RTL8168.R4D`
- Image scope: `slim`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

RX interrupts acknowledge and classify causes only. DriverApi v23 wakes the
common `net-rx` task for RX or controller-recovery work; TX and link-only
causes do not enter the protocol path. The task retains a CPU-owned descriptor
when Netcore's bounded copying queue reports backpressure.

## Build

On Windows:

    Build.bat

On Linux or macOS:

    ./Build.sh

The build starters resolve the current local R4OS dependency checkouts through
`Settings.R4S`. The URL and hash entries in `build.zig.zon` record the
last verified standalone dependency identities; workspace builds use the
mapped local checkouts.

## Documentation

Detailed German technical notes from the migration are preserved in
`DOCUMENTATION.de.txt`. Source-transfer provenance is recorded in
`PROVENANCE.txt`.

## License

Original R4OS material is licensed under Apache License 2.0. See `LICENSE`
and `NOTICE`. Any repository-specific external material is documented in
`THIRD_PARTY_NOTICES.md`.
