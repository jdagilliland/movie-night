{
  description = "Movie Night: paste text, get a short link";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    haskell-flake.url = "github:srid/haskell-flake";
  };

  outputs = inputs@{ nixpkgs, flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;
      imports = [ inputs.haskell-flake.flakeModule ];

      perSystem = { self', pkgs, ... }: {
        haskellProjects.default = {
          # movie-night.cabal needs base >=4.20, i.e. GHC 9.10 or newer.
          basePackages = pkgs.haskell.packages.ghc910;

          devShell.tools = hp: {
            inherit (hp)
              cabal-install
              haskell-language-server
              hspec-discover;
          };
        };

        packages.default = self'.packages.movie-night;
      };
    };
}
