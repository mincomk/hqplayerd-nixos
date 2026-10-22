# hqplayerd for NixOS

HQPlayer Embedded **6.1.1** (`hqplayerd-6.1.1-5.fc44.x86_64.rpm` from Signalyst) packaged for
NixOS, because nixpkgs' `hqplayerd` is 5.13.2 (fc37) and marked `broken`: 5.x links
libsoup 2 through gupnp/gssdp for the old UPnP-AV stack, and libsoup 2 was removed from
nixpkgs over its CVEs. HQPlayer 6 dropped that stack entirely, so 6.x needs no insecure
package at all.

## Use it

```nix
# flake.nix
inputs.hqplayerd-nixos.url = "path:/home/allen/projects/hqplayerd-nixos";

# in the module list
hqplayerd-nixos.nixosModules.default   # overlay: replaces pkgs.hqplayerd
{
  services.hqplayerd.enable = true;
  services.hqplayerd.openFirewall = true;   # 8088 web UI, 4321 control API
}
```

Or just the package: `nix build .#hqplayerd`, `nix run .#hqplayerd -- --version`.

## What is inside

```
$out/bin/hqplayerd                # wrapper: execs the vendor binary through the NixOS loader
$out/libexec/hqplayerd            # vendor binary, byte-identical to upstream
$out/lib/libsgllnx64-2.29.02.so   # HQPlayer's private library, shipped in the rpm
$out/etc/hqplayer/hqplayerd.xml   # default config (the module installs this to /etc on first start)
$out/var/lib/hqplayer/web         # web UI (the module copies this to /var/lib/hqplayer)
$out/lib/systemd/system/hqplayerd.service
```

The layout is what `services.hqplayerd` expects: it references `$pkg/var/lib/hqplayer/web`
and `$pkg/etc/hqplayer/hqplayerd.xml` from its `preStart`.

## Why the vendor binary is not patched

The binary is a 245 MB `ET_EXEC` with CUDA fatbins compiled into it. Every attempt to
patch it broke it: patchelf 0.19.2 `--set-rpath`, nixpkgs' `shrink-rpath` hook, and
`strip` each re-laid the file out so that `.dynamic` ended up inside a read-only
`PT_LOAD`, and `ld.so` then died with SIGSEGV inside `dl_main` before `main()` ran.
(`strip` after patchelf also produces `.dynstr`/version corruption outright.)

So the ELF is left alone and `$out/bin/hqplayerd` is a 6-line shell wrapper that sets
`LD_LIBRARY_PATH` and execs `ld-linux-x86-64.so.2` directly. `dontStrip` and
`dontPatchELF` are set so fixupPhase does not touch the files afterwards. The build's
`installCheckPhase` runs `hqplayerd --version`, so a successful build is a build whose
binary actually starts.

## License

HQPlayer Embedded 6 looks for its key at `~/.hqplayer/hqplayerd6-key.xml` or
`/etc/hqplayer/hqplayerd6-key.xml` (or via the `/key` web endpoint once auth exists).
Note that nixpkgs' `services.hqplayerd.licenseFile` installs `hqplayerd4-key.xml`, which
is the 5.x/4.x name and is **not** picked up by 6.x. Until that module option is fixed,
install the key with:

```nix
environment.etc."hqplayer/hqplayerd6-key.xml".source = ./hqplayerd6-key.xml;
```

Without a key it runs in trial mode (restarts every 30 minutes).

## Hardcoded paths (from upstream, not ours)

- app/data root: `/var/lib/hqplayer/`
- config: `/etc/hqplayer/hqplayerd.xml` (or `$HOME/.hqplayer/hqplayerd.xml`)
- auth: `/etc/hqplayer/hqplayerd-auth.xml`
- web UI: port 8088, control API: 4321

`services.hqplayerd` creates those directories with tmpfiles, so use the module rather
than running the wrapper by hand.

## CUDA / OpenCL

`/run/opengl-driver/lib` is on the wrapper's `LD_LIBRARY_PATH`, so CUDA offload works on a
host where `hardware.nvidia` (or another driver module) provides it. The daemon reports
its devices at startup, e.g. `CUDA device 0: NVIDIA GeForce RTX 4090`.
