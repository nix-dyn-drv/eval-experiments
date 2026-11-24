{
  description = "a small flake to try the sandboxed-evaluation experiment on";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs = { self, nixpkgs }:
    let systems = [ "x86_64-linux" "aarch64-linux" ];
    in {
      packages = nixpkgs.lib.genAttrs systems (system: {
        hello = nixpkgs.legacyPackages.${system}.hello;
        default = self.packages.${system}.hello;
      });
    };
}
