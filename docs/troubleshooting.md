# Troubleshooting

Check these first:

```sh
systemctl status hqplayerd
journalctl -u hqplayerd -b -n 100 --no-pager
nix-store -q --references $(readlink -f result 2>/dev/null || echo /run/current-system)
```

## The daemon dies instantly with SIGSEGV, before any log line

```
hqplayerd.service: Main process exited, code=killed, status=11/SEGV
```

Symptom of the vendor binary having been patched. `hqplayerd` is a 245 MB `ET_EXEC` with
embedded CUDA fatbins, and patchelf moves `.dynamic` into a read-only `PT_LOAD`, after which
`ld.so` faults in `dl_main` before `main()` runs. Symptoms are identical for `strip` and for
`shrink-rpath`.

Do not add `autoPatchelfHook`, `addDriverRunpath`, `patchelf`, or a manual
`--set-interpreter`. `hqplayerd.nix` sets `dontStrip` and `dontPatchELF` and runs the untouched
binary through the NixOS loader for exactly this reason. If you forked the derivation, revert
to the wrapper. See [internals](internals.md).

## Works, but restarts every 30 minutes

Trial mode: the license key was not found. HQPlayer 6 reads
`/etc/hqplayer/hqplayerd6-key.xml` or `~/.hqplayer/hqplayerd6-key.xml`. The nixpkgs option
`services.hqplayerd.licenseFile` installs the key as **`hqplayerd4-key.xml`** (the 4.x/5.x
name), which 6.x ignores. Install it yourself instead:

```nix
environment.etc."hqplayer/hqplayerd6-key.xml".source = ./hqplayerd6-key.xml;
```

Then check what the daemon actually sees:

```sh
ls -l /etc/hqplayer/
journalctl -u hqplayerd -b | grep -i -E 'license|trial'
```

## `configuration file not found!` and the service exits

`/etc/hqplayer/hqplayerd.xml` is missing. The module's `preStart` writes it from the package on
first start, but that only runs under `services.hqplayerd`. If you ran `$out/bin/hqplayerd` by
hand, reproduce the module's setup:

```sh
sudo install -d -o hqplayer -g hqplayer /var/lib/hqplayer /var/lib/hqplayer/home /etc/hqplayer
sudo -u hqplayer cp -r $(nix build --print-out-paths .#hqplayerd)/var/lib/hqplayer/web /var/lib/hqplayer/
sudo install -m 0644 $(nix build --print-out-paths .#hqplayerd)/etc/hqplayer/hqplayerd.xml /etc/hqplayer/
```

Or just use the module.

## `/var/lib/hqplayer/web/web` exists after a restart

Harmless artifact of nixpkgs' `preStart`, which does `cp -r $pkg/var/lib/hqplayer/web
/var/lib/hqplayer` unconditionally, so on every restart after the first it nests the copy one
level deeper. The top-level `web` directory (the one being served) stays intact. Remove the
nested copy if it bothers you, or override `systemd.services.hqplayerd.preStart`:

```nix
systemd.services.hqplayerd.preStart = lib.mkForce ''
  rm -rf /var/lib/hqplayer/web
  cp -r ${pkgs.hqplayerd}/var/lib/hqplayer/web /var/lib/hqplayer/
  chmod -R u+wX /var/lib/hqplayer/web
  if [ ! -f /etc/hqplayer/hqplayerd.xml ]; then
    install -m 0644 ${pkgs.hqplayerd}/etc/hqplayer/hqplayerd.xml /etc/hqplayer/hqplayerd.xml
  fi
'';
```

That also makes web UI updates actually replace the old files.

## Web UI loads but everything asks for credentials / no `/auth` page

Authentication has not been provisioned, or was provisioned with a lost password. Reset:

```sh
sudo systemctl stop hqplayerd
sudo rm -f /etc/hqplayer/hqplayerd-auth.xml
sudo systemctl start hqplayerd
```

Then open `http://<host>:8088/auth` and set the management user. To provision it from the
shell instead: `sudo -u hqplayer $(nix build --print-out-paths .#hqplayerd)/bin/hqplayerd -s <user> <password>`.

If you set `services.hqplayerd.auth.username` and `auth.password`, remember both values end up
in the nix store, in the system closure, and in the world-readable service environment.

## No CUDA devices

The daemon prints its devices on startup. `CUDA devices: 0` means `/run/opengl-driver/lib`
was empty or incompatible when it started.

- `hardware.nvidia.enable = true` (or `hardware.graphics.enable` for OpenCL-only setups), and
  `nixpkgs.config.allowUnfree` for the driver.
- The wrapper already puts `/run/opengl-driver/lib` first in `LD_LIBRARY_PATH`; if you built a
  custom wrapper, keep that.
- Rebuild and restart after a driver change; the path is resolved at exec time, so a restart is
  enough. Check with `journalctl -u hqplayerd -b | grep -i cuda`.

## Web UI unreachable from another machine

`openFirewall` only covers 8088 and 4321, and only for the host's own firewall. Check
`systemctl status hqplayerd`, then `firewall-cmd --list-ports` or `nft list ruleset`, and that
the service binds all interfaces (it does by default).

## Build fails on aarch64 or with `unsupported system`

Expected. The upstream rpm is `x86_64` only, and the flake declares `systems = [
"x86_64-linux" ]`. There is no source to build.

## `hash mismatch` after bumping `version`

Either the rpm changed upstream or you edited `version` without the URL. Take the hash from the
build error's `got:` line, or:

```sh
nix hash convert --hash-algo sha256 --to sri <the got: value>
```

Also confirm the file exists: `curl -sI https://www.signalyst.eu/bins/hqplayerd/fc44/hqplayerd-<version>.fc44.x86_64.rpm`.

## Roon does not see the zone

Roon discovers HQPlayer over the control API on 4321. Confirm the daemon is running and that
port 4321 is reachable from the Roon Core host, then in Roon: Settings > Audio > (the host
appears as an HQPlayer zone). If the HQPlayer zone never appears, check that authentication is
not blocking the API and that `network-online.target` was reached (`systemctl status
network-online.target`).
