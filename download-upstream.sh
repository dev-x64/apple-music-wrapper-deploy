#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# -eq 1 ]] || { echo "usage: download-upstream.sh DESTINATION" >&2; exit 2; }
destination="$1"
[[ ! -e "$destination" ]] || { echo "destination already exists: $destination" >&2; exit 1; }

api="https://api.github.com/repos/WorldObservationLog/wrapper"
artifact_name="wrapper-lite-linux-x86_64"
curl_args=(--fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 600 \
  --header 'Accept: application/vnd.github+json' \
  --header 'User-Agent: apple-music-wrapper-deploy')
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

echo "Finding the latest successful lite build on GitHub..."
curl "${curl_args[@]}" \
  "$api/actions/workflows/build-lite.yml/runs?branch=lite&status=success&per_page=1" \
  -o "$temp_dir/runs.json"
read -r run_id commit < <(python3 - "$temp_dir/runs.json" <<'PY'
import json, sys
runs = json.load(open(sys.argv[1], encoding="utf-8"))["workflow_runs"]
if not runs:
    raise SystemExit("No successful lite workflow run found")
run = runs[0]
print(run["id"], run["head_sha"])
PY
)
[[ "$run_id" =~ ^[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "GitHub returned an invalid workflow run" >&2; exit 1;
}

curl "${curl_args[@]}" "$api/actions/runs/$run_id/artifacts?per_page=100" \
  -o "$temp_dir/artifacts.json"
expected_digest="$(python3 - "$temp_dir/artifacts.json" "$artifact_name" "$commit" <<'PY'
import json, sys
artifacts = json.load(open(sys.argv[1], encoding="utf-8"))["artifacts"]
for artifact in artifacts:
    if (artifact["name"] == sys.argv[2] and not artifact["expired"]
            and artifact["workflow_run"]["head_sha"] == sys.argv[3]):
        print(artifact["digest"])
        break
else:
    raise SystemExit("The latest successful lite run has no usable native artifact")
PY
)"
[[ "$expected_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "GitHub did not provide an artifact SHA-256 digest" >&2; exit 1;
}

# GitHub requires authentication to download Actions artifacts. nightly.link
# resolves this public GitHub artifact to GitHub's own time-limited download URL.
echo "Downloading prebuilt lite artifact for ${commit:0:12}..."
curl "${curl_args[@]}" \
  "https://nightly.link/WorldObservationLog/wrapper/actions/runs/$run_id/$artifact_name.zip" \
  -o "$temp_dir/upstream.zip"
actual_digest="$(sha256sum "$temp_dir/upstream.zip" | awk '{print $1}')"
[[ "sha256:$actual_digest" == "$expected_digest" ]] || {
  echo "Downloaded artifact checksum does not match GitHub" >&2; exit 1;
}

mkdir "$temp_dir/extracted"
python3 - "$temp_dir/upstream.zip" "$temp_dir/extracted" <<'PY'
import pathlib, sys, zipfile
destination = pathlib.Path(sys.argv[2])
with zipfile.ZipFile(sys.argv[1]) as archive:
    for member in archive.infolist():
        path = pathlib.PurePosixPath(member.filename)
        if path.is_absolute() or ".." in path.parts:
            raise SystemExit("Unsafe path in GitHub artifact")
    archive.extractall(destination)
PY
for required in wrapper-lite-rootless rootfs/system/bin/lite rootfs/system/bin/linker64; do
  [[ -s "$temp_dir/extracted/$required" ]] || {
    echo "Missing $required in GitHub artifact" >&2; exit 1;
  }
done
chmod +x "$temp_dir/extracted/wrapper-lite-rootless" \
  "$temp_dir/extracted/rootfs/system/bin/lite" \
  "$temp_dir/extracted/rootfs/system/bin/linker64"
printf '%s\n' "$commit" > "$temp_dir/extracted/.source-commit"
mv "$temp_dir/extracted" "$destination"
echo "Ready: ${commit:0:12}"
