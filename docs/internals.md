# How the packaging works

Everything here is the consequence of two upstream facts: HQPlayer 6 is shipped as a Fedora
rpm with a 245 MB vendor binary that embeds CUDA fatbins, and that binary must not be
rewritten.

## Why 5.x from nixpkgs cannot be used

nixpkgs' `hqplayerd` is `5.13.2-39` from the `fc37` directory. Two problems:

1. 5.x links the old UPnP-AV stack: `libsoup-2.4` via `gupnp`, `gssdp` and `gupnp-av`. libsoup 2
   was removed from nixpkgs for security reasons, so the package is marked `broken` and does
   not evaluate on current unstable.
2. The `fc37` rpm URL is gone; upstream only serves the current Fedora release, so the fetch
   itself fails with 403.

The comment in the nixpkgs derivation guessed that HQPlayer 6 would not need the UPnP stack.
That guess is correct. `rpm -qpR` on `hqplayerd-6.1.1-5.fc44.x86_64.rpm` lists only:

```
alsa-lib, cairo, lame, libmicrohttpd, mpg123, libogg, libudev, libusb-0.1, libomp19,
plus the bundled libsgllnx64-2.29.02.so
```

`flac`, `wavpack`, `libgmpris`, `gupnp`, `gssdp`, `gupnp-av` and `libsoup` are all gone.
Nothing insecure is needed anywhere in the closure.

## Why the vendor binary is not patched

The binary is an `ET_EXEC` with CUDA fatbins compiled into it. Every attempt to rewrite it
produced a binary that died before `main()`:

| Attempt | Result |
| --- | --- |
| patchelf 0.19.2 `--set-rpath` | `.dynamic` relocated into a read-only `PT_LOAD`; `ld.so` SIGSEGV in `dl_main` |
| `addDriverRunpath` (adds an rpath via patchelf) | same |
| fixupPhase's `shrink-rpath` | same |
| `strip` after patchelf | same, plus `.dynstr` and version symbol corruption |

The mechanism: patchelf rewrites the program headers and moves `.dynamic`, and on this file
the result lands inside a segment mapped read-only, so the dynamic loader faults while it is
still starting up. There is no `main()` frame and no useful trace, only a SIGSEGV.

The fix is to not touch the ELF at all:

- `dontStrip = true` and `dontPatchELF = true` keep fixupPhase's hooks off the file.
- The rpm payload is copied byte for byte to `$out/libexec/hqplayerd`.
- `$out/bin/hqplayerd` is a small shell wrapper that sets `LD_LIBRARY_PATH` and execs the
  NixOS glibc loader against the untouched binary:

```sh
#!/nix/store/.../bash
# Executes the vendor binary through the NixOS glibc loader; see hqplayerd.nix.
if [ -n "$LD_LIBRARY_PATH" ]; then
  export LD_LIBRARY_PATH="<deps>:$out/lib:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="<deps>:$out/lib:/run/opengl-driver/lib"
fi
exec <ld-linux-x86-64.so.2> <$out/libexec/hqplayerd> "$@"
```

`$out/lib` is on the path because HQPlayer's private `libsgllnx64-2.29.02.so` comes out of the
rpm and sits there. `/run/opengl-driver/lib` is on it so CUDA and OpenCL work when
`hardware.nvidia` (or another driver module) provides them.

### The check that makes this trustworthy

`doInstallCheck = true` with `installCheckPhase = ''$out/bin/hqplayerd --version''`. The binary
has no help flag: `--version` starts the daemon, prints the banner and the CUDA device list,
then exits on the missing configuration file. So **a successful build is a build whose binary
starts**, not merely one whose files were installed. Any regression in the wrapper (missing
library, wrong loader, accidental patch) fails the build.

## Dependency mapping

The rpm's `Requires` names Fedora packages; the mapping to nixpkgs is in `hqplayerd.nix`:

| rpm requirement | nixpkgs attribute |
| --- | --- |
| `alsa-lib` | `alsa-lib` |
| `cairo` | `cairo` |
| `lame-libs` | `lame` |
| `libmicrohttpd` | `libmicrohttpd` |
| `mpg123-libs` | `mpg123` |
| `libogg` | `libogg` |
| `libudev` | `systemd` |
| `libusb-0.1` | `libusb-compat-0_1` |
| `libomp19` | `llvmPackages_19.openmp` |
| `libstdc++`, `libgcc_s` | `stdenv.cc.cc.lib`, `stdenv.cc.cc.libgcc` |

`rpmextract` is the only native build input besides the compiler's own runtime.

## Package layout

```
$out/bin/hqplayerd                # wrapper: execs the vendor binary through the NixOS loader
$out/bin/hqplayer-*.sh            # upstream helper scripts (backup, restore, USB gadget)
$out/libexec/hqplayerd            # vendor binary, byte-identical to upstream
$out/lib/libsgllnx64-2.29.02.so   # HQPlayer's private library, from the rpm
$out/etc/hqplayer/hqplayerd.xml   # default config; the module installs it on first start
$out/var/lib/hqplayer/web         # web UI; the module copies it to /var/lib/hqplayer
$out/share/doc/hqplayerd/         # upstream readme.txt, LICENSE, sample configs
$out/lib/systemd/system/hqplayerd.service
```

That shape is dictated by the nixpkgs module: its `preStart` reads
`$pkg/var/lib/hqplayer/web` and `$pkg/etc/hqplayer/hqplayerd.xml`.

`postInstall` rewrites the unit's `ExecStart` from `/usr/bin/hqplayerd` to `$out/bin/hqplayerd`
and removes the `NetworkManager-wait-online.service` requirement, which does not exist on a
`systemd-networkd` host. The remaining `Requires=network-online.target sound.target
systemd-udev-settle.service` is left alone.

Upstream's unit sets `User=hqplayer`, `Nice=-10`, `IOSchedulingClass=realtime`,
`LimitMEMLOCK=4G`, `LimitRTPRIO=98` and reads `EnvironmentFile=-/etc/default/hqplayerd` (the
latter is a hook for `HQPLAYER_*` environment variables documented in the upstream readme).

## Why the flake replaces `pkgs.hqplayerd` with an overlay

`services.hqplayerd` in nixpkgs hard-codes `pkgs.hqplayerd`, so there is no option to point it
at another derivation. An overlay is the only way to make the module use this package without
forking the module. `nixosModules.default` therefore does one thing:

```nix
nixpkgs.overlays = [ self.overlays.default ];
```

and nothing else.
