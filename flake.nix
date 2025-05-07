{
  description = "A flake for building DTB viewer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, ... }@inputs: inputs.utils.lib.eachSystem [
    "x86_64-linux"
    "aarch64-linux"
    "x86_64-darwin"
    "aarch64-darwin"
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

          osPkgs = with pkgs; {
            aarch64-darwin = [];
            x86_64-darwin = [];
            x86_64-linux = [ gtk3 glibc ];
            aarch64-linux = [ gtk3 glibc ];
          }.${system} or (throw "Unsupported system: ${system}");

          nativeBuildInputs = with pkgs; [
            zig
            glfw
            pkg-config
          ] ++ osPkgs;
        };
        packages.default = pkgs.callPackage ./package.nix {};
      });
}
