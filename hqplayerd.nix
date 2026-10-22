{
  lib,
  stdenv,
  fetchurl,
  rpmextract,
  alsa-lib,
  cairo,
  lame,
  libmicrohttpd,
  libogg,
  libusb-compat-0_1,
  llvmPackages_19,
  mpg123,
  systemd,
}:

# HQPlayer Embedded 6.x, shipped by Signalyst as a Fedora 44 rpm.
#
# Why this exists: nixpkgs' hqplayerd is 5.13.2 (fc37) and is `broken` on
# current master because 5.x links libsoup 2 (via gupnp/gssdp, the old UPnP-AV
# stack) and libsoup 2 was dropped from nixpkgs for security reasons.
# `rpm -qpR` on the 6.x package shows that stack is gone:
#
#   alsa-lib, cairo, lame, libmicrohttpd, mpg123, libogg, libudev,
#   libusb-0.1, libomp19, plus the bundled libsgllnx64-2.29.02.so
#
# So 6.x builds against plain nixpkgs with no insecure package at all.
#
# Why the vendor binary is not patched and is run through the loader instead:
# it is a 245 MB ET_EXEC with CUDA fatbins in it, and every patchelf that has
# touched it (0.19.2's --set-rpath, and nixpkgs' shrink-rpath hook or strip
# running afterwards) re-laid the file out so that .dynamic landed inside a
# read-only PT_LOAD; ld.so then SIGSEGV'd in dl_main before main() ran, at
# every single variant.  Leaving the ELF byte-identical and exec'ing it through
# `ld-linux --library-path` sidesteps the whole class of breakage, and the
# wrapper is what the systemd unit and services.hqplayerd call anyway.
stdenv.mkDerivation (finalAttrs: {
  pname = "hqplayerd";
  version = "6.1.1-5";

  src = fetchurl {
    url = "https://www.signalyst.eu/bins/hqplayerd/fc44/hqplayerd-${finalAttrs.version}.fc44.x86_64.rpm";
    hash = "sha256-qPrVWBO5K7R8HqWo5T1X2lLpoqgzTKbxDQWornkEzwc=";
  };

  nativeBuildInputs = [ rpmextract ];

  buildInputs = [
    alsa-lib
    cairo
    lame
    libmicrohttpd
    libogg
    libusb-compat-0_1
    llvmPackages_19.openmp
    mpg123
    stdenv.cc.cc.lib # libstdc++
    stdenv.cc.cc.libgcc # libgcc_s
    systemd # libudev
  ];

  unpackPhase = ''
    rpmextract $src
  '';

  dontConfigure = true;
  dontBuild = true;

  # The vendor binary is shipped stripped and must not be rewritten.
  dontStrip = true;
  dontPatchELF = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin $out/libexec $out/lib $out/etc $out/lib/systemd $out/share/doc $out/var/lib

    # vendor executable, untouched
    cp -v ./usr/bin/hqplayerd $out/libexec/hqplayerd

    # helper scripts
    cp -v ./usr/bin/hqplayer-*.sh $out/bin/

    # HQPlayer's own private library (libsgllnx64), bundled by upstream
    cp -v ./opt/hqplayerd/lib/*.so $out/lib/

    # configuration
    cp -rv ./etc/hqplayer $out/etc/

    # systemd unit + the state tree the NixOS module copies the web UI out of
    cp -rv ./usr/lib/systemd/system $out/lib/systemd/
    cp -rv ./usr/share/doc/hqplayerd $out/share/doc/
    cp -rv ./var/lib/hqplayer $out/var/lib/

    cat > $out/bin/hqplayerd <<'WRAPPER'
#!@shell@
# Executes the vendor binary through the NixOS glibc loader; see hqplayerd.nix.
if [ -n "$LD_LIBRARY_PATH" ]; then
  export LD_LIBRARY_PATH="@libpath@:/run/opengl-driver/lib:$LD_LIBRARY_PATH"
else
  export LD_LIBRARY_PATH="@libpath@:/run/opengl-driver/lib"
fi
exec @loader@ @exe@ "$@"
WRAPPER
    chmod +x $out/bin/hqplayerd

    runHook postInstall
  '';

  postInstall = ''
    substituteInPlace $out/lib/systemd/system/hqplayerd.service \
      --replace-fail /usr/bin/hqplayerd $out/bin/hqplayerd \
      --replace "NetworkManager-wait-online.service" ""

    substituteInPlace $out/bin/hqplayerd \
      --replace-fail @shell@ "${stdenv.shell}" \
      --replace-fail @libpath@ "${lib.makeLibraryPath finalAttrs.buildInputs}:$out/lib" \
      --replace-fail @loader@ "${stdenv.cc.bintools.dynamicLinker}" \
      --replace-fail @exe@ "$out/libexec/hqplayerd"

    patchShebangs $out/bin
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    $out/bin/hqplayerd --version
  '';

  meta = {
    homepage = "https://www.signalyst.com/custom.html";
    description = "High-end upsampling multichannel software embedded HD-audio player";
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
  };
})
