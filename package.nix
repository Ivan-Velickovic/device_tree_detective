#
# Copyright 2024, UNSW
# SPDX-License-Identifier: BSD-2-Clause
#
{
  zig
, libxkbcommon
, pkg-config
, gtk3
, glibc
, stdenv
, nix-gitignore
, lib
, linkFarm
, fetchzip
}:

  let deps = linkFarm "zig-packages" [
    {
      name = "dtb-0.0.0-gULdmf4ZAgA6G3AGbbbs2GQNA3JneiyO36jMDmq8XSwz";
      path = fetchzip {
        url = "https://github.com/Ivan-Velickovic/dtb.zig/archive/4101efa09f2863a27367aae449f9186c700cb132.tar.gz";
        hash = "sha256-LMlGzPHoVpDQgf33V3s19gmnTP4YPIqcw3GEogDkvxQ=";
      };
    }
    {
      name = "zig_objc-0.0.0-Ir_Sp8YTAQBjTWe2mkgNDNSj73vaoT8FHNVeSqKZ7cBo";
      path = fetchzip {
        url = "https://github.com/mitchellh/zig-objc/archive/3ab0d37c7d6b933d6ded1b3a35b6b60f05590a98.tar.gz";
        hash = "sha256-JUKDny6iMEd0niJInciWJKf8Ez1+k2a7n6sO4X1mXMQ=";
      };
    }
    {
      name = "N-V-__8AAL40TADEbrysYHBl-UIZO4KiG4chP8pLDVDINGH4";
      path = fetchzip {
        url = "https://github.com/glfw/glfw/archive/refs/tags/3.4.tar.gz";
        hash = "sha256-FcnQPDeNHgov1Z07gjFze0VMz2diOrpbKZCsI96ngz0=";
      };
    }
  ];
in
  stdenv.mkDerivation rec {
    name = "Device Tree Detective";
    src = nix-gitignore.gitignoreSource [] ./.;

    meta = with lib; {
      homepage = "https://github.com/Ivan-Velickovic/device_tree_detective";
      maintainers = with maintainers; [ Ivan-Velickovic ];
    };

    buildPhase = ''
      runHook preBuild

      zig build -Doptimize=ReleaseSafe --color off -p $out

      # TODO: fix these icons
      mkdir -p $out/share/icons/hicolor/128x128@2/apps
      cp ${./assets/icons/macos.png} $out/share/icons/hicolor/128x128@2/apps/device_tree_detective.png

      mkdir -p $out/share/applications
      cp ${./packaging/device-tree-detective.desktop} $out/share/applications

      runHook postBuild
    '';

    postPatch = ''
      export ZIG_LOCAL_CACHE_DIR=$(mktemp -d)
      export ZIG_GLOBAL_CACHE_DIR=$(mktemp -d)
      ln -s ${deps} $ZIG_GLOBAL_CACHE_DIR/p
    '';

    buildInputs = [ libxkbcommon gtk3 glibc ];
    nativeBuildInputs = [ zig pkg-config ];
  }
