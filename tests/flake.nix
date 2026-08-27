# Dev-only flake so the top-level one stays input-free for consumers.
#   nix build ./tests#checks.x86_64-linux.vm-transfer
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flakelet.url = "github:Mic92/flakelet";
    flakelet.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { nixpkgs, flakelet, ... }:
    {
      checks.x86_64-linux.vm-transfer = nixpkgs.legacyPackages.x86_64-linux.testers.runNixOSTest (
        import ./vm-transfer.nix {
          flakeletModule = flakelet.nixosModules.flakelet;
          providerModule = ../modules/provider.nix;
        }
      );
    };
}
