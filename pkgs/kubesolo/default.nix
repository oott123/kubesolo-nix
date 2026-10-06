{
  lib,
  stdenv,
  buildGoModule,
  fetchFromGitHub,
  fetchurl,
  dockerTools,
  zstd,
}:

let
  deps = import ./deps.nix;

  goarch =
    {
      x86_64-linux = "amd64";
      aarch64-linux = "arm64";
    }
    .${stdenv.hostPlatform.system}
      or (throw "kubesolo: unsupported platform ${stdenv.hostPlatform.system}");

  containerd = fetchurl {
    url = "https://github.com/containerd/containerd/releases/download/v${deps.containerd.version}/containerd-${deps.containerd.version}-linux-${goarch}.tar.gz";
    hash = deps.containerd.hash.${goarch};
  };

  crun = fetchurl {
    url = "https://github.com/containers/crun/releases/download/${deps.crun.version}/crun-${deps.crun.version}-linux-${goarch}";
    hash = deps.crun.hash.${goarch};
  };

  cni-plugins = fetchurl {
    url = "https://github.com/containernetworking/plugins/releases/download/${deps.cni-plugins.version}/cni-plugins-linux-${goarch}-${deps.cni-plugins.version}.tgz";
    hash = deps.cni-plugins.hash.${goarch};
  };

  pullImage =
    image:
    dockerTools.pullImage {
      inherit (image) imageName imageDigest;
      hash = image.hash.${goarch};
      finalImageName = image.imageName;
      finalImageTag = image.imageTag;
      os = "linux";
      arch = goarch;
    };

  corednsImage = pullImage deps.images.coredns;
  pauseImage = pullImage deps.images.pause;
in
buildGoModule (finalAttrs: {
  pname = "kubesolo";
  version = "1.2.1";

  src = fetchFromGitHub {
    owner = "portainer";
    repo = "kubesolo";
    tag = "v${finalAttrs.version}";
    hash = "sha256-SeZlPc8YUUXMITllgvK0f6vHkuzgAmA/O0CkWBvKZr8=";
  };

  patches = [
    # Startup pulls images that are not embedded (local-path-provisioner, Portainer agent, d2k)
    # with containerd's default resolver, which ignores the registry mirrors in hosts.toml.
    ./registry-hosts-for-image-pull.patch
  ];

  vendorHash = "sha256-ldNptIfy9iOmKPTeEN4BhMnfWQuk2Iic9CBB8WfB0/E=";

  subPackages = [
    "cmd/kubesolo"
    "cmd/kubesoloctl"
  ];

  nativeBuildInputs = [ zstd ];

  env = {
    CGO_ENABLED = 1;
    # Enables the SQLite dbstat table kine uses to report the database size.
    CGO_CFLAGS = "-DSQLITE_ENABLE_DBSTAT_VTAB";
  };

  ldflags = [
    "-s"
    "-w"
    "-X main.Version=v${finalAttrs.version}"
    "-X main.BuildDate=1970-01-01T00:00:00Z"
    "-X k8s.io/component-base/version.gitVersion=v1.35.7+kubesolo-v${finalAttrs.version}"
  ];

  # Lays out internal/core/embedded/bin the way build/download-deps.sh does, for //go:embed.
  preBuild = ''
    bin=internal/core/embedded/bin
    mkdir -p $bin/containerd/bin $bin/cni $bin/images

    tar -xzf ${containerd} -C $bin/containerd bin/containerd-shim-runc-v2
    zstd -19 -q --rm $bin/containerd/bin/containerd-shim-runc-v2

    zstd -19 -q ${crun} -o $bin/crun.zst

    tar -xzf ${cni-plugins} -C $bin/cni ./bridge ./host-local ./portmap ./loopback
    for plugin in bridge host-local portmap loopback; do
      zstd -19 -q --rm $bin/cni/$plugin
    done

    gzip -nc ${corednsImage} > $bin/images/coredns.tar.gz
    gzip -nc ${pauseImage} > $bin/images/pause.tar.gz
  '';

  overrideModAttrs = _: { preBuild = ""; };

  # The unit tests need root, a container runtime or network access.
  doCheck = false;

  passthru = {
    inherit
      containerd
      crun
      cni-plugins
      corednsImage
      pauseImage
      ;
  };

  meta = {
    description = "Ultra-lightweight single-node Kubernetes for resource-constrained edge devices";
    homepage = "https://github.com/portainer/kubesolo";
    changelog = "https://github.com/portainer/kubesolo/releases/tag/v${finalAttrs.version}";
    license = lib.licenses.mit;
    mainProgram = "kubesolo";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode # embedded containerd shim, crun and CNI plugins come from upstream releases
    ];
  };
})
