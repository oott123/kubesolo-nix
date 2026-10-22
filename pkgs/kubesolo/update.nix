{
  writeShellApplication,
  coreutils,
  curl,
  gawk,
  git,
  gnused,
  jq,
  nix-prefetch-docker,
  nix-update,
  skopeo,
}:

writeShellApplication {
  name = "kubesolo-update";
  runtimeInputs = [
    coreutils
    curl
    gawk
    git
    gnused
    jq
    nix-prefetch-docker
    nix-update
    skopeo
  ];
  text = builtins.readFile ./update.sh;
}
