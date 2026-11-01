#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
qa_head="$(git rev-parse HEAD)"
if [[ -n "$(git status --porcelain)" ]]; then
  echo 'Commit the verified source before creating reference-profile evidence.' >&2
  exit 1
fi
qa_image_head="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' bookorbit57-qa-profile:local 2>/dev/null || true)"
qa_min_gib=5
if [[ "$qa_image_head" == "$qa_head" ]]; then qa_min_gib=2; fi
python3 - "$qa_min_gib" <<'PY'
import shutil
import sys
minimum = int(sys.argv[1])
if shutil.disk_usage('.').free < minimum * 1024**3:
    raise SystemExit(f'Reference-profile setup needs at least {minimum} GiB free on the host SSD.')
PY
qa_docker_free="$(docker run --rm --entrypoint df pgvector/pgvector:pg18 --output=avail -B1 / | tail -1 | tr -d ' ')"
if (( qa_docker_free < qa_min_gib * 1024 * 1024 * 1024 )); then
  echo "Reference-profile setup needs at least $qa_min_gib GiB free in Docker storage." >&2
  exit 1
fi
qa_output="$PWD/native/build/qa-profile"
mkdir -p "$qa_output"
python3 -c 'from pathlib import Path; [Path("native/build/qa-profile", name).unlink(missing_ok=True) for name in ["stop", "ready.json", "profile.json"]]'
if [[ "$qa_image_head" != "$qa_head" ]]; then
  docker build --build-arg "QA_SOURCE_COMMIT=$qa_head" -f native/scripts/qa-profile.Dockerfile -t bookorbit57-qa-profile:local .
fi
docker run --rm --name "bookorbit57-profile-$$" --cpus=4 --memory=8g \
  -p 127.0.0.1:55458:55458 -p 127.0.0.1:55459:55459 \
  -v "$qa_output:/output" bookorbit57-qa-profile:local
