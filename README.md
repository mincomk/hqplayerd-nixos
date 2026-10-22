# hqplayerd for NixOS

HQPlayer Embedded **6.1.1** (`hqplayerd-6.1.1-5.fc44.x86_64.rpm` from Signalyst) packaged for
NixOS, because nixpkgs' `hqplayerd` is still 5.13.2 (fc37) and marked `broken`: 5.x links
libsoup 2 through gupnp/gssdp for the old UPnP-AV stack, and libsoup 2 was removed from
nixpkgs over its CVEs. HQPlayer 6 dropped that stack, so 6.x needs no insecure package at all.

This flake gives you:

- `packages.hqplayerd` (and `packages.default`): the package.
- `overlays.default`: replaces `pkgs.hqplayerd`, which is what makes the existing
  `services.hqplayerd` NixOS module use 6.x.
- `nixosModules.default` (alias `nixosModules.hqplayerd`): applies that overlay for you.

Not affiliated with Signalyst. HQPlayer itself is proprietary software and is not
redistributed here: the flake fetches the official rpm at build time.

- [Install on NixOS](#install-on-nixos)
- [Package only](#package-only)
- [License key](#license-key)
- [Using it](#using-it)
- [Module options](#module-options)
- [Bumping the version](#bumping-the-version)
- [Troubleshooting](docs/troubleshooting.md)
- [How the packaging works](docs/internals.md)

## Requirements

- `x86_64-linux`. The upstream rpm is x86_64 only, so there is nothing to support on arm.
- `allowUnfree` for `hqplayerd`. When you consume this flake as an overlay the package is built
  with **your** nixpkgs, so the setting has to be on your side (see below).
- No insecure packages, no libsoup 2, no `permittedInsecurePackages` entries.

## Install on NixOS

`flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hqplayerd-nixos.url = "github:mincomk/hqplayerd-nixos";
    # Reuse the nixpkgs your system already has instead of pulling a second copy.
    hqplayerd-nixos.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { nixpkgs, hqplayerd-nixos, ... }: {
    nixosConfigurations.hqplayer = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        hqplayerd-nixos.nixosModules.default
        ./configuration.nix
      ];
    };
  };
}
```

`configuration.nix`:

```nix
{ pkgs, ... }:
{
  nixpkgs.config.allowUnfreePredicate =
    pkg: builtins.elem (pkgs.lib.getName pkg) [ "hqplayerd" ];

  services.hqplayerd = {
    enable = true;
    openFirewall = true; # TCP 8088 (web UI) and 4321 (control API)
  };
}
```

Then `sudo nixos-rebuild switch --flake .#hqplayer`.

The module creates the `hqplayer` user, the state tree under `/var/lib/hqplayer`, puts the
web UI and a default `hqplayerd.xml` in place on first start, and starts
`hqplayerd.service`. Nothing else has to be configured to get the web UI up.

If you prefer to write your own module, apply `hqplayerd-nixos.overlays.default` yourself and
enable `services.hqplayerd` from nixpkgs as usual. Our `nixosModules.default` is exactly that
overlay and nothing more.

## Package only

```sh
nix build github:mincomk/hqplayerd-nixos#hqplayerd
nix run   github:mincomk/hqplayerd-nixos -- --version
# or, in a checkout:
nix build .#hqplayerd && ./result/bin/hqplayerd --version
```

`--version` prints `Signalyst HQPlayer Embedded v6.1.1` and then exits with
`configuration file not found!` when there is no config yet. That is expected: the binary has
no separate help flag and starts the daemon instead.

Do not run the package binary by hand for real use. It hard-codes `/var/lib/hqplayer` and
`/etc/hqplayer`, and those directories plus the `hqplayer` user only exist because the module
sets them up. Use `services.hqplayerd`.

## License key

HQPlayer 6 looks for its key at `~/.hqplayer/hqplayerd6-key.xml` or
`/etc/hqplayer/hqplayerd6-key.xml`, or you can upload it through the `/key` endpoint of the web
UI once authentication exists. Without a key it runs in trial mode and restarts every 30
minutes.

**Do not use `services.hqplayerd.licenseFile`**: that nixpkgs option installs the file as
`hqplayerd4-key.xml`, which is the 4.x/5.x name and is not picked up by 6.x. Put the key in
yourself:

```nix
environment.etc."hqplayer/hqplayerd6-key.xml".source = ./hqplayerd6-key.xml;
```

Keep that file out of the world-readable store if you care about it (`source` copies it into
`/etc`, mode 0644). `sudo install -m 0600 hqplayerd6-key.xml /etc/hqplayer/hqplayerd6-key.xml`
after the first boot is the alternative.

## Using it

1. Open `http://<host>:8088`. On a fresh install go to `/auth` and set the management
   username and password; most pages are locked until you do.
2. Configure output: `alsa` for a local DAC, `network` for a Signalyst Network Audio Adapter
   (NAA). Input, filters, dither/modulator and convolution all live in the same web UI and
   write to `/etc/hqplayer/hqplayerd.xml`.
3. Roon: Settings > Audio should list the host as an HQPlayer zone. Point Roon at
   `localhost:4321` (or the host IP).
4. Check the log for device detection: `journalctl -u hqplayerd -b`, look for
   `CUDA device 0: ...` and the selected output device.

Secrets belong in `/auth`, not in your NixOS config: an option value ends up world-readable in
the nix store and in the system closure. `services.hqplayerd.auth.username` and `auth.password`
do exist and the module runs `hqplayerd -s` with them, but only use them for a throwaway
password.

CUDA/OpenCL offload works out of the box on a host where `hardware.nvidia` provides
`/run/opengl-driver/lib`: the wrapper puts that directory on `LD_LIBRARY_PATH`. The daemon
reports its devices at startup.

## Module options

These are the nixpkgs `services.hqplayerd` options. This flake does not add or rename any of
them; it only makes `pkgs.hqplayerd` be 6.x.

| Option | Type | Default | Meaning |
| --- | --- | --- | --- |
| `services.hqplayerd.enable` | bool | `false` | Enable the daemon, user, firewall rule and tmpfiles. |
| `services.hqplayerd.openFirewall` | bool | `false` | Open TCP 8088 and 4321. |
| `services.hqplayerd.config` | lines or null | `null` | Written to `/etc/hqplayer/hqplayerd.xml`. Leave `null` to keep the default config. |
| `services.hqplayerd.auth.username` | str or null | `null` | Web UI user, provisioned with `hqplayerd -s`. Requires `password`. |
| `services.hqplayerd.auth.password` | str or null | `null` | Password for the above. |
| `services.hqplayerd.licenseFile` | path or null | `null` | **Wrong file name for 6.x**, see [License key](#license-key). |

Runtime layout after the module has started once:

| Path | What |
| --- | --- |
| `/var/lib/hqplayer` | state, library, buffers (`HOME`) |
| `/var/lib/hqplayer/web` | web UI, copied out of the package on start |
| `/etc/hqplayer/hqplayerd.xml` | configuration |
| `/etc/hqplayer/hqplayerd-auth.xml` | credentials |
| `/etc/hqplayer/hqplayerd6-key.xml` | license key |

## Bumping the version

Signalyst publishes per-Fedora-release directories, so a new HQPlayer release means a new rpm:

1. Edit `version` in `hqplayerd.nix` (`6.1.1-5` style) and the `fcNN` path in its `url` if
   Signalyst moved to a newer Fedora release.
2. `nix build .#hqplayerd` and take the hash from the error message, or
   `nix hash convert --hash-algo sha256 --to sri <hash>` from the `got:` line.
3. `nix build .#hqplayerd` again. `installCheckPhase` runs `hqplayerd --version`, so a build
   that succeeds is a binary that actually starts.
4. Re-check the dependency list: `nix run nixpkgs#rpm -- -qpR <rpm>` (or `rpm -qpR` on any
   Fedora-ish host). If upstream adds a library, add it to `buildInputs`.

## Repo layout

| File | What |
| --- | --- |
| `flake.nix` | `packages.hqplayerd`, `overlays.default`, `nixosModules.default`. |
| `hqplayerd.nix` | The derivation: unpack the rpm, install, wrap, check. |
| `docs/internals.md` | Why the binary is left unpatched, package layout, dependency list. |
| `docs/troubleshooting.md` | Known failure modes and fixes. |

## License

The packaging code in this repository is MIT licensed, see [LICENSE](LICENSE). That covers the
nix expressions only. HQPlayer Embedded is proprietary software by Jussi Laako / Signalyst, is
not redistributed here, and needs a license key you buy from
<https://www.signalyst.com/custom.html>.
