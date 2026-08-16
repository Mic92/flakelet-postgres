{
  description = "postgres/v1 flakelet contract and its provider";

  outputs =
    { self }:
    {
      nixosModules.provider = ./modules/provider.nix;
      nixosModules.default = self.nixosModules.provider;
    };
}
