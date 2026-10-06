{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.kubesolo;
  settingsFormat = pkgs.formats.yaml { };

  configFile = settingsFormat.generate "kubesolo-config.yaml" (
    {
      apiVersion = "kubesolo.io/v1alpha1";
      kind = "Config";
    }
    // cfg.settings
  );

  kubeconfig = "${cfg.settings.path}/pki/admin/admin.kubeconfig";

  # symlinkJoin keeps the shell completions and man pages of the original package.
  kubectlWrapped = pkgs.symlinkJoin {
    name = "kubesolo-${cfg.kubectl.package.name}";
    paths = [
      cfg.kubectl.package
    ]
    ++ lib.optional (cfg.kubectl.package ? man) cfg.kubectl.package.man;
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/kubectl --set-default KUBECONFIG ${kubeconfig}
    '';
    meta.mainProgram = "kubectl";
  };
in
{
  options.services.kubesolo = {
    enable = lib.mkEnableOption "KubeSolo, a single-node Kubernetes distribution";

    package = lib.mkPackageOption pkgs "kubesolo" { };

    settings = lib.mkOption {
      description = ''
        KubeSolo configuration, written to {file}`/etc/kubesolo/config.yaml`.
        `apiVersion` and `kind` are filled in automatically. See
        <https://github.com/portainer/kubesolo/blob/main/docs/configuration/config-file.md>
        for every setting.
      '';
      default = { };
      example = lib.literalExpression ''
        {
          network.nodeIP = "192.168.1.10";
          kubernetes.apiServer.extraSANs = [ "k8s.example.com" ];
          storage.localPath.enabled = false;
        }
      '';
      type = lib.types.submodule {
        freeformType = settingsFormat.type;

        options.path = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/kubesolo";
          description = ''
            Directory holding certificates, the cluster database and container state.
            KubeSolo cannot move existing state, so changing this starts a fresh cluster.
          '';
        };
      };
    };

    environmentFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/run/secrets/kubesolo.env";
      description = ''
        Environment file passed to the service, for settings that must stay out of
        the Nix store, e.g. `KUBESOLO_PORTAINER_EDGE_KEY`. Every setting has a
        `KUBESOLO_*` variable, and variables override {option}`settings`.
      '';
    };

    extraFlags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [ "--debug" ];
      description = ''
        Extra command-line flags. Flags are deprecated upstream; prefer {option}`settings`.
      '';
    };

    kubectl = {
      enable = lib.mkEnableOption ''
        a `kubectl` wrapper that uses the KubeSolo admin kubeconfig unless
        {env}`KUBECONFIG` is already set. The kubeconfig is only readable by root,
        so run it with `sudo`
      '';

      package = lib.mkPackageOption pkgs "kubectl" { };
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the Kubernetes API server port (6443) in the firewall.";
    };
  };

  config = lib.mkIf cfg.enable {
    warnings = lib.optional (cfg.settings.api.enabled or false) ''
      services.kubesolo: the configuration API cannot persist changes, because
      /etc/kubesolo/config.yaml is generated from services.kubesolo.settings.
    '';

    environment.systemPackages = [ cfg.package ] ++ lib.optional cfg.kubectl.enable kubectlWrapped;

    # kubesoloctl reads this path by default.
    environment.etc."kubesolo/config.yaml".source = configFile;

    boot.kernelModules = [
      "overlay"
      "br_netfilter"
      "nf_conntrack"
    ];

    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.bridge.bridge-nf-call-iptables" = 1;
      "net.bridge.bridge-nf-call-ip6tables" = 1;
    };

    networking.firewall = {
      # Pods reach the API server and CoreDNS through the cni0 bridge.
      trustedInterfaces = [ "cni0" ];
      allowedTCPPorts = lib.optional cfg.openFirewall 6443;
    };

    # Keep host network managers off the pod bridge and veths, which they would otherwise configure.
    networking.dhcpcd.denyInterfaces = [
      "cni0"
      "veth*"
    ];
    networking.networkmanager.unmanaged = [
      "interface-name:cni0"
      "interface-name:veth*"
    ];

    systemd.services.kubesolo = {
      description = "KubeSolo single-node Kubernetes";
      documentation = [ "https://github.com/portainer/kubesolo" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      # KubeSolo reads its configuration only at startup.
      restartTriggers = [ configFile ];

      path = with pkgs; [
        iptables
        nftables
        kmod
        conntrack-tools
        iproute2
        util-linux
        e2fsprogs
        fuse-overlayfs
      ];

      serviceConfig = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs (
          [
            (lib.getExe cfg.package)
            "--config=/etc/kubesolo/config.yaml"
          ]
          ++ cfg.extraFlags
        );
        EnvironmentFile = lib.optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "always";
        RestartSec = 3;
        OOMScoreAdjust = -500;
        LimitNOFILE = 1048576;
        LimitNPROC = "infinity";
        LimitCORE = "infinity";
        TasksMax = "infinity";
      };
    };
  };
}
