{ lib, pkgs, ... }:

let
  goarch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${pkgs.stdenv.hostPlatform.system};

  # Not embedded in the binary, so KubeSolo pulls it at startup. The VM has no network
  # access, so the pull only succeeds through the local mirror below.
  localPathProvisionerImage = pkgs.dockerTools.pullImage {
    imageName = "rancher/local-path-provisioner";
    imageDigest = "sha256:1eba82e9c386038b4af6d69cca7519fac738c28c42735ed48ce70c882ad0d80f";
    hash =
      {
        amd64 = "sha256-8xdKZ0almPn/zsamUZE8f8AC0d71maqux/q27K5PtLg=";
        arm64 = "sha256-YaD4Va7aosUGLUAZwJSUlpwJ6h09TH7426TkrKXiHAQ=";
      }
      .${goarch};
    finalImageName = "rancher/local-path-provisioner";
    finalImageTag = "v0.0.36";
    os = "linux";
    arch = goarch;
  };

  kubesolo = pkgs.callPackage ../pkgs/kubesolo { };

  # The same KubeSolo reporting another version, so the test can upgrade without a second release.
  upgraded = kubesolo.overrideAttrs (old: {
    version = "${old.version}-test";
    inherit (old) src goModules;
  });

  # Fails the datastore check, so a switch to it must abort.
  broken = pkgs.writeShellScriptBin "kubesolo" "exit 1" // {
    version = "${kubesolo.version}-broken";
  };

  # Passes the datastore check but never runs KubeSolo, so it never becomes healthy.
  unhealthy =
    pkgs.writeShellScriptBin "kubesolo" ''
      case "$1" in --upgrade-check-datastore=*) exec ${lib.getExe kubesolo} "$@" ;; esac
      exec sleep infinity
    ''
    // {
      version = "${kubesolo.version}-unhealthy";
    };

  state = "/var/lib/kubesolo/nixos-upgrade";
in
{
  name = "kubesolo";

  nodes.machine = {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
    };

    services.dockerRegistry = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 5000;
    };

    systemd.services.seed-registry = {
      wantedBy = [ "multi-user.target" ];
      requires = [ "docker-registry.service" ];
      after = [ "docker-registry.service" ];
      before = [ "kubesolo.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.skopeo}/bin/skopeo --insecure-policy copy --retry-times 10 --dest-tls-verify=false \
          docker-archive:${localPathProvisionerImage} \
          docker://127.0.0.1:5000/rancher/local-path-provisioner:v0.0.36
      '';
    };

    services.kubesolo = {
      enable = true;
      kubectl.enable = true;
      registries."docker.io".mirrors = [ "http://127.0.0.1:5000" ];
    };

    specialisation = {
      upgraded.configuration.services.kubesolo.package = upgraded;
      broken.configuration.services.kubesolo.package = broken;
      unhealthy.configuration.services.kubesolo = {
        package = unhealthy;
        upgrade.healthTimeout = 60;
      };
    };
  };

  testScript = ''
    machine.wait_for_unit("seed-registry.service")
    machine.wait_for_unit("kubesolo.service")
    machine.wait_for_file("/var/lib/kubesolo/pki/admin/admin.kubeconfig")
    machine.wait_until_succeeds("kubectl get node -o name | grep -q node/", timeout=600)
    machine.wait_until_succeeds("kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=600)
    machine.wait_until_succeeds(
        "kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=coredns --timeout=10s",
        timeout=600,
    )
    machine.wait_until_succeeds(
        "kubectl -n local-path-storage wait --for=condition=Ready pod -l app=local-path-provisioner --timeout=10s",
        timeout=600,
    )
    machine.succeed("journalctl -u docker-registry | grep -q 'rancher/local-path-provisioner/manifests'")

    machine.succeed(
        "kubectl run pause --image=docker.io/portainer/pause:latest --image-pull-policy=Never"
    )
    machine.wait_until_succeeds("kubectl wait --for=condition=Ready pod/pause --timeout=10s", timeout=300)

    machine.succeed("kubesoloctl config get network.mtu")

    hosts = machine.succeed("cat /var/lib/kubesolo/containerd/registry/docker.io/hosts.toml")
    assert 'server = "https://registry-1.docker.io"' in hosts, hosts
    assert 'http://127.0.0.1:5000' in hosts, hosts

    def switch(to):
        return f"/run/booted-system/specialisation/{to}/bin/switch-to-configuration test"

    def wait_ready():
        machine.wait_until_succeeds("kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=300)
        machine.wait_until_succeeds("kubectl wait --for=condition=Ready pod/pause --timeout=10s", timeout=300)
        # New connections through a ClusterIP, which kube-proxy has to route again after a restart.
        machine.wait_until_succeeds("${pkgs.curl}/bin/curl -sSkf -m 5 https://10.43.0.1/readyz", timeout=120)

    # The pod sandboxes and the pause pod all run the pause binary. A restart that lost them would
    # start new ones.
    pause_pids = "pgrep -x pause | sort"

    with subtest("restarting KubeSolo keeps the pods running"):
        before = machine.succeed(pause_pids)
        machine.succeed("systemctl restart kubesolo")
        wait_ready()
        machine.sleep(30)
        assert machine.succeed(pause_pids) == before

    with subtest("a version that cannot open the datastore aborts the switch"):
        pid = machine.succeed("systemctl show -P MainPID kubesolo")
        machine.fail(switch("broken"))
        assert machine.succeed("systemctl show -P MainPID kubesolo") == pid
        machine.succeed("grep -qx v${kubesolo.version} ${state}/current")

    with subtest("an upgrade backs up the datastore and waits for the new version"):
        before = machine.succeed(pause_pids)
        machine.succeed(switch("upgraded"))
        machine.succeed(
            "kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'"
            " | grep -q -- '+kubesolo-v${upgraded.version}$'"
        )
        machine.succeed("grep -qx from=v${kubesolo.version} ${state}/backup/manifest")
        machine.fail("test -e ${state}/pending")
        assert machine.succeed(pause_pids) == before
        machine.succeed("kubectl create configmap upgraded")

    with subtest("an unhealthy version fails the switch, and switching back restores the datastore"):
        machine.fail(switch("unhealthy"))
        machine.succeed("grep -qx v${unhealthy.version} ${state}/pending")
        machine.succeed(switch("upgraded"))
        machine.succeed("journalctl -u kubesolo | grep -q 'restored the datastore of v${upgraded.version}'")
        machine.fail("test -e ${state}/backup")
        machine.succeed("kubectl get configmap upgraded")
        wait_ready()
  '';
}
