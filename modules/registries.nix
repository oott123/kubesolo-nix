{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kubesolo;
  tomlFormat = pkgs.formats.toml { };

  registryModule =
    { name, config, ... }:
    {
      options = {
        server = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "https://${if name == "docker.io" then "registry-1.docker.io" else name}";
          defaultText = lib.literalMD "`https://<name>`, or `https://registry-1.docker.io` for `docker.io`";
          description = ''
            Upstream registry URL, used when every mirror fails.
            Set to `null` to never fall back to the upstream registry.
          '';
        };
        mirrors = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          example = [ "https://mirror.example.com/docker.io" ];
          description = ''
            Mirror URLs with `pull` and `resolve` capabilities.
            Keys in the generated file are sorted, so containerd tries mirrors in alphabetical order.
          '';
        };
        settings = lib.mkOption {
          type = tomlFormat.type;
          default = { };
          description = ''
            Content of {file}`hosts.toml`, see
            <https://github.com/containerd/containerd/blob/main/docs/hosts.md>.
          '';
        };
      };

      config.settings = lib.mkMerge [
        (lib.mkIf (config.server != null) { server = lib.mkDefault config.server; })
        {
          host = lib.genAttrs config.mirrors (_: {
            capabilities = lib.mkDefault [
              "pull"
              "resolve"
            ];
          });
        }
      ];
    };
in
{
  options.services.kubesolo.registries = lib.mkOption {
    type = lib.types.attrsOf (lib.types.submodule registryModule);
    default = { };
    example = lib.literalExpression ''
      {
        "docker.io".mirrors = [ "https://mirror.example.com/docker.io" ];
        "ghcr.io".mirrors = [ "https://mirror.example.com/ghcr.io" ];
      }
    '';
    description = ''
      containerd registry host configuration, keyed by registry namespace
      (e.g. `docker.io`, `ghcr.io`, or `_default` for every other registry).
      Image references must be fully qualified for a mirror to apply.
    '';
  };

  config = lib.mkIf (cfg.enable && cfg.registries != { }) {
    environment.etc = lib.mapAttrs' (
      name: registry:
      lib.nameValuePair "kubesolo-registry/${name}/hosts.toml" {
        source = tomlFormat.generate "hosts.toml" registry.settings;
      }
    ) cfg.registries;

    # containerd reads hosts.toml on every pull, so linking to /etc picks up changes without a restart.
    systemd.tmpfiles.rules = [
      "d ${cfg.settings.path}/containerd 0755 root root -"
      "L+ ${cfg.settings.path}/containerd/registry - - - - /etc/kubesolo-registry"
    ];
  };
}
