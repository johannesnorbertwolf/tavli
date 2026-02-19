{ pkgs ? import <nixpkgs> {} }:
let
  dev = import ./.idx/dev.nix { inherit pkgs; };
in
pkgs.mkShell {
  buildInputs = dev.packages;
}
