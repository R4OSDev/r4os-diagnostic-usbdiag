# USBDIAG.R4X

`USBDIAG.R4X` is an independent R4OS diagnostic program implemented in Zig.

## Package

- Version: `0.1.6`
- Image target: `/R4OS/SOFTWARE/TERMINAL/DIAG/USBDIAG.R4X`
- Image scope: `test`
- Canonical project manifest: `module.R4MF`

The manifest is the single source of truth for the artifact, imports, image
target, and package metadata.

The default protocol suite validates HID, BOT and USB SCSI dispatch,
including 4Kn READ/WRITE(16) CDBs and a READ CAPACITY(16) result beyond the
32-bit LBA boundary. `/READSTRESS` retains the repeated file checksum check for
a real mounted filesystem path; physical USB coverage requires an attached device.

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

## Generation 2

The normal Start2/Query2 diagnostic preserves all original HID/BOT/SCSI and 4Kn/64-bit-LBA protocol fixtures. `/READSTRESS PATH [PASSES]` uses full file metadata, the common UTF8 no-quote argument cursor and a shared stream transfer. The four-KB chunks, FNV1a checksum, independent pass comparison, default eight/max 64 passes and original u32 path-reader range remain. Counters and offsets stay u64; the SDK rejects an unavailable offset rather than truncating it. A pass has a thirty-second monotonic deadline and checks cancellation. Protocol selftests and virtual NTFS reads do not certify a physical USB device.
