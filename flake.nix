{
  description = "A flake for building DTB viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    zig-overlay.url = "github:mitchellh/zig-overlay";
    zig-overlay.inputs.nixpkgs.follows = "nixpkgs";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, zig-overlay, ... }@inputs: inputs.utils.lib.eachSystem [
    "x86_64-linux"
    "aarch64-linux"
  ]
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
        zig = zig-overlay.packages.${system}."0.15.1";
      in
      {
        devShells.default = pkgs.mkShell rec {
          name = "dev-shell";

          buildInputs = with pkgs; [
            pkg-config
            libxkbcommon
            gtk3
            glibc
            xorg.libX11.dev
          ];

          nativeBuildInputs = [ zig pkgs.pkg-config ];
        };
        packages.default = pkgs.callPackage ./package.nix { zig = zig; };
      });
}
