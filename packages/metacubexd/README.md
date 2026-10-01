# MetaCubeXD packaging

The checked-in 1.273.1 server/UI archive is retained from the working deployment.
Its source checkout revision was `8bbc8f58fef71148a94fb5c0ff808f79b057337d` in
the MetaCubeX/metacubexd repository, with the patch in `patches/` applied.
Use the revision rather than assuming the version string uniquely identifies it.

Rebuild procedure (Node 22 and pnpm 10.34.1): check out that revision, apply
`patches/default-backend-secret.patch`, run `pnpm install --frozen-lockfile`,
then `pnpm build:ui` and `pnpm build:server`. Package `apps/server/.output/`
as `server/` and `packages/ui/.output/public/` as `ui-dist/` in the archive.
The package expression removes the static config.js and its Nitro static asset
entry so the dynamic config route is reachable. This source rebuild procedure
is documented, but the archive has not been rebuilt during the module refactor.

The dynamic config exposes the control token and mihomo secret to browsers
that can access the dashboard: treat it as a trusted-LAN administrative service.
Neither credential is baked into the archive.

mihomo v1.19.27 is selected by host architecture, with pinned hashes for
aarch64-linux and x86_64-linux. Other architectures fail explicitly.
