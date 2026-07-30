{
  description = "kbshot - screenshot an object on screen, picked with the keyboard";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    nixpkgs,
    flake-utils,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages.default = import ./default.nix {inherit pkgs;};
      packages.kbshot = import ./default.nix {inherit pkgs;};

      devShells.default = pkgs.mkShell {
        packages = [
          (pkgs.python3.withPackages (ps: with ps; [numpy scipy pillow]))
          pkgs.wl-kbptr
          pkgs.grim
          pkgs.tesseract
          pkgs.wl-clipboard
          pkgs.libnotify
        ];
      };
    });
}
