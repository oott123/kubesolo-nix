# Updates KubeSolo to the given version, or the latest release, and regenerates deps.json from
# build/download-deps.sh, types/const.go and go.mod at that tag. Hashes are only prefetched again
# for artifacts whose version or image digest changed.
# Usage: kubesolo-update [VERSION]

repo=portainer/kubesolo
cd "$(git rev-parse --show-toplevel)"
deps=pkgs/kubesolo/deps.json

if [[ $# -gt 0 ]]; then
  version=${1#v}
else
  version=$(git ls-remote --tags --refs "https://github.com/$repo" |
    sed -nE 's|.*refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)$|\1|p' | sort -V | tail -n 1)
  [[ -n $version ]] || { echo "no release tag found for $repo" >&2; exit 1; }
fi
old_version=$(nix eval --raw .#kubesolo.version)
echo "kubesolo: $old_version -> $version" >&2

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for file in build/download-deps.sh types/const.go go.mod; do
  curl -fsSL "https://raw.githubusercontent.com/$repo/v$version/$file" -o "$tmp/${file##*/}"
done

# Prints the value of a VAR="value" assignment in download-deps.sh.
script_var() {
  local value
  value=$(sed -nE "s/^$1=\"([^\"]+)\"\$/\1/p" "$tmp/download-deps.sh")
  [[ -n $value ]] || { echo "$1 not found in download-deps.sh" >&2; exit 1; }
  echo "$value"
}

# Prints the value of a Name = "value" Go constant in types/const.go.
go_const() {
  local value
  value=$(sed -nE "s/^\s*$1\s*=\s*\"([^\"]+)\".*/\1/p" "$tmp/const.go")
  [[ -n $value ]] || { echo "$1 not found in types/const.go" >&2; exit 1; }
  echo "$value"
}

# Prints {version, hash} for a release artifact. @arch@ in the URL is replaced by the Go arch.
pin_release() {
  local name=$1 version=$2 url=$3 arch hash hashes='{}'
  for arch in amd64 arm64; do
    hash=$(jq -r --arg n "$name" --arg v "$version" --arg a "$arch" \
      'if .[$n].version == $v then .[$n].hash[$a] else empty end' "$deps")
    if [[ -z $hash ]]; then
      echo "prefetching $name $version ($arch)" >&2
      hash=$(nix store prefetch-file --json "${url//@arch@/$arch}" | jq -r .hash)
    fi
    hashes=$(jq -c --arg a "$arch" --arg h "$hash" '.[$a] = $h' <<<"$hashes")
  done
  jq -n --arg v "$version" --argjson h "$hashes" '{version: $v, hash: $h}'
}

# Prints the dockerTools.pullImage arguments for an image reference. Tags such as the `latest`
# of the pause image are resolved to the digest they currently point to.
pin_image() {
  local key=$1 ref=${2#docker.io/} name tag digest arch hash hashes='{}'
  name=${ref%:*}
  tag=${ref##*:}
  digest=$(skopeo inspect --override-os linux --override-arch amd64 "docker://$name:$tag" | jq -r .Digest)
  for arch in amd64 arm64; do
    hash=$(jq -r --arg k "$key" --arg n "$name" --arg d "$digest" --arg a "$arch" \
      '.images[$k] | if .imageName == $n and .imageDigest == $d then .hash[$a] else empty end' "$deps")
    if [[ -z $hash ]]; then
      echo "prefetching $name:$tag ($arch)" >&2
      hash=$(nix-prefetch-docker --quiet --json --os linux --arch "$arch" \
        --image-name "$name" --image-digest "$digest" \
        --final-image-name "$name" --final-image-tag "$tag" | jq -r .hash)
    fi
    hashes=$(jq -c --arg a "$arch" --arg h "$hash" '.[$a] = $h' <<<"$hashes")
  done
  jq -n --arg n "$name" --arg t "$tag" --arg d "$digest" --argjson h "$hashes" \
    '{imageName: $n, imageTag: $t, imageDigest: $d, hash: $h}'
}

containerd_version=$(script_var CONTAINERD_VERSION)
crun_version=$(script_var CRUN_VERSION)
cni_version=$(script_var CNI_VERSION)
kubernetes_version=$(awk '$1 == "k8s.io/kubernetes" && $2 != "=>" { print $2 }' "$tmp/go.mod")
[[ -n $kubernetes_version ]] || { echo "k8s.io/kubernetes not found in go.mod" >&2; exit 1; }
coredns_image=$(go_const DefaultCoreDNSImage)
pause_image=$(go_const DefaultSandboxImage)

containerd=$(pin_release containerd "$containerd_version" \
  "https://github.com/containerd/containerd/releases/download/v$containerd_version/containerd-$containerd_version-linux-@arch@.tar.gz")
crun=$(pin_release crun "$crun_version" \
  "https://github.com/containers/crun/releases/download/$crun_version/crun-$crun_version-linux-@arch@")
cni=$(pin_release cni-plugins "$cni_version" \
  "https://github.com/containernetworking/plugins/releases/download/$cni_version/cni-plugins-linux-@arch@-$cni_version.tgz")
coredns=$(pin_image coredns "$coredns_image")
pause=$(pin_image pause "$pause_image")

jq -n \
  --arg kubernetes "$kubernetes_version" \
  --argjson containerd "$containerd" \
  --argjson crun "$crun" \
  --argjson cni "$cni" \
  --argjson coredns "$coredns" \
  --argjson pause "$pause" \
  '{
    kubernetes: { version: $kubernetes },
    containerd: $containerd,
    crun: $crun,
    "cni-plugins": $cni,
    images: { coredns: $coredns, pause: $pause }
  }' >"$tmp/deps.json"
mv "$tmp/deps.json" "$deps"

# Updates version, the source hash and vendorHash. Fails if the patches no longer apply.
if [[ $version != "$old_version" ]]; then
  nix-update --flake kubesolo --version "$version"
fi
