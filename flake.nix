{
  description = "Gnosis VPN test environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix.url = "github:numtide/treefmt-nix";

    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [ inputs.treefmt-nix.flakeModule ];
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      perSystem =
        { config, pkgs, ... }:
        {
          treefmt = {
            projectRootFile = "justfile";

            settings.global.excludes = [ "configs/*.tmpl" ];

            programs.nixfmt.enable = true;

            programs.deno.enable = true;
            settings.formatter.deno.excludes = [
              "*.toml"
              "*.yml"
              "*.yaml"
            ];
          };

          devShells.default = pkgs.mkShell {
            packages =
              with pkgs;
              [
                jq
                wireguard-tools
                gettext
                config.treefmt.build.wrapper
              ]
              ++ pkgs.lib.attrValues config.treefmt.build.programs;
          };

          formatter = config.treefmt.build.wrapper;
        };
    };
}
