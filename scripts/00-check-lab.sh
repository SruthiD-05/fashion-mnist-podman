#!/usr/bin/env bash
# Checks what your lab machine can do before you start.
cd "$(dirname "$0")/.."
ok()   { printf '  \e[32mOK\e[0m   %s\n' "$1"; }
bad()  { printf '  \e[31mFAIL\e[0m %s\n' "$1"; }
probe() { curl -sS -o /dev/null -m 10 -I "$2" 2>/dev/null && ok "$1 ($2)" || bad "$1 ($2)"; }

echo "== Tools"
for t in podman skopeo podman-compose oc curl; do
  command -v "$t" >/dev/null && ok "$t: $($t --version 2>/dev/null | head -1)" || bad "$t not installed"
done
echo "== Podman"
podman info --format '  rootless={{.Host.Security.Rootless}}  cgroup={{.Host.CgroupsVersion}}  storage={{.Store.GraphDriverName}}'
echo "  SELinux: $(getenforce 2>/dev/null || echo n/a)"
echo "  CPUs: $(nproc)   free RAM: $(free -g | awk '/Mem/{print $7}') GB   free disk in \$HOME: $(df -h ~ | awk 'NR==2{print $4}')"
echo "== Network access (only the UBI registry is required; the rest is optional)"
probe "Red Hat UBI registry"   https://registry.access.redhat.com/v2/
probe "PyPI"                   https://pypi.org/simple/flask/
probe "Fashion-MNIST dataset"  http://fashion-mnist.s3-website.eu-central-1.amazonaws.com/t10k-labels-idx1-ubyte.gz
probe "UBI RPM repo (microdnf)" https://cdn-ubi.redhat.com/content/public/ubi/dist/ubi9/9/x86_64/appstream/os/repodata/repomd.xml
echo
echo "UBI registry OK -> you can do the whole lab (dataset + Python wheels are bundled)."
echo "UBI RPM repo FAIL -> fine: scripts/01-build.sh switches the runtime stage automatically."
echo "UBI registry FAIL -> read section 14 'Offline lab' in README.md."
echo "== Bundled files"
echo "  dataset: $(ls dataset/*.gz 2>/dev/null | wc -l)/4 files   wheels: $(ls wheels/*.whl 2>/dev/null | wc -l) files"
(cd dataset && sha256sum -c SHA256SUMS 2>/dev/null) | sed 's/^/  /' || true
