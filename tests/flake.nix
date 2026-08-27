# Dev-only flake so the top-level one stays input-free for consumers.
#   nix build ./tests#checks.x86_64-linux.transfer
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flakelet.url = "github:Mic92/flakelet/docs-split";
    flakelet.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, flakelet, ... }:
    {
      checks.x86_64-linux.transfer = nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest (
        import ./transfer.nix {
          flakeletModule = flakelet.nixosModules.flakelet;
          inherit (flakelet.lib) buildArtifact;
          providerModule = ../modules/provider.nix;
        }
      );
    };
}
