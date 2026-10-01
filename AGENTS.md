# Repository maintenance

This repository builds a NixOS router. Keep runtime configuration and image
assembly separate and reuse the same hardware/service modules in both.

## Ownership

- `hosts/`: deployment-specific addresses, interface assignments, MACs and SSH keys.
- `hardware/`: kernel, DTB, vendor assets, watchdog and bootloader installation.
- `modules/`: independently configurable system, networking and service modules.
- `profiles/`: role composition; do not hardcode a particular host here.
- `images/`: partitioning and firmware/image assembly only.
- `packages/`: package versions, architecture mappings and UI fixes.
- `scripts/legacy/` and hardware history are archival, not supported entrypoints.
- Keep the original NOTES.md under the R4S hardware directory.

## Configuration boundaries

Never commit subscription URLs, tokens, environment secrets, live profiles or
`/var/lib/metacubexd`. Nix seeds missing profiles; the WebUI owns existing data.
Do not introduce periodic PATCH jobs or overwrite UI edits at startup.
Do not enable Docker/Podman for this deployment.
Preserve hardware-specific BSP and watchdog workarounds. Do not silently replace
them with a mainline kernel, a generic R4S DTB or another board's bootloader.
Keep large assets and build outputs out of Git; verify assets before use.

## Verification and deployment

Use `just assets-check`, `just check`, and `just build` for system changes.
For image changes also evaluate and build `just image` on a supported builder.
Check shell syntax for changed scripts. Test module disabling and alternate
architectures when changing option or package interfaces.
Record separately: evaluation, successful build, and actual boot verification.
Do not claim the latter based on the former.

Keep deployment distinct from repository refactoring. Network bridge changes
can disconnect SSH: prefer build/boot to switch for remote topology changes.
Do not use the live 1GB R4S for full evaluation/build validation; it has shown
severe memory pressure and SSH stalls. Use a separate adequately sized builder.
Use the configured NixOS bootloader install interface; do not assume extlinux
is the board's actual boot path. Back up live profiles before authorized state
migrations. Rebuilding or rolling back NixOS does not roll back application data.
Do not auto-select flash devices. Do not delete firmware backups or generated
images without an explicit cleanup request. Update README and justfile whenever
supported commands or asset requirements change.
