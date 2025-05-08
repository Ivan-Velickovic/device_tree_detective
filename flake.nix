{
  description = "A flake for building DTB viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, ... }@inputs: inputs.utils.lib.eachSystem [
    "x86_64-linux"
    "aarch64-linux"
  ]
    (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        devShells.default = pkgs.mkShell rec {
          name = "dev-shell";

          buildInputs = with pkgs; [
            pkg-config
            libxkbcommon
            gtk3
            glibc
          ];

          nativeBuildInputs = with pkgs; [ zig pkg-config ];
        };
        packages.default = pkgs.callPackage ./package.nix {};
      });
}
