{ pkgs, ... }:

{
  name = "kubesolo";

  nodes.machine = {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      diskSize = 4096;
    };

    services.kubesolo = {
      enable = true;
      # The VM has no network access, so only images embedded in the binary are available.
      settings.storage.localPath.enabled = false;
    };

    environment.systemPackages = [ pkgs.kubectl ];
    environment.variables.KUBECONFIG = "/var/lib/kubesolo/pki/admin/admin.kubeconfig";
  };

  testScript = ''
    machine.wait_for_unit("kubesolo.service")
    machine.wait_for_file("/var/lib/kubesolo/pki/admin/admin.kubeconfig")
    machine.wait_until_succeeds("kubectl get node -o name | grep -q node/", timeout=600)
    machine.wait_until_succeeds("kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=600)
    machine.wait_until_succeeds(
        "kubectl -n kube-system wait --for=condition=Ready pod -l k8s-app=coredns --timeout=10s",
        timeout=600,
    )

    machine.succeed(
        "kubectl run pause --image=docker.io/portainer/pause:latest --image-pull-policy=Never"
    )
    machine.wait_until_succeeds("kubectl wait --for=condition=Ready pod/pause --timeout=10s", timeout=300)

    machine.succeed("kubesoloctl config get network.mtu")
  '';
}
