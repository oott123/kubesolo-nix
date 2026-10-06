{ pkgs, ... }:

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
        ${pkgs.skopeo}/bin/skopeo --insecure-policy copy --dest-tls-verify=false \
          docker-archive:${localPathProvisionerImage} \
          docker://127.0.0.1:5000/rancher/local-path-provisioner:v0.0.36
      '';
    };

    services.kubesolo = {
      enable = true;
      kubectl.enable = true;
      registries."docker.io".mirrors = [ "http://127.0.0.1:5000" ];
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
  '';
}
