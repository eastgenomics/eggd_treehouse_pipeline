#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# Docker Image Repackaging & DNAnexus Upload
#
# Usage:
#   ./repackage_image.sh <old_image> <new_image> <dx_project> <dx_dest_folder>
#
# Arguments:
#   old_image       full source image ref (tag or sha256)
#   new_image       target name:tag for the rebuilt OCI image
#   dx_project      DNAnexus project name or ID  (passed to: dx select)
#   dx_dest_folder  destination folder path inside the DNAnexus project
#
# Examples:
#   ./repackage_image.sh \
#     "quay.io/ucsc_cgl/cutadapt:1.9--6bd44edd2b8f8f17e25c5a268fedaab65fa851d2" \
#     "cutadapt:1.0-oci" \
#     "my_dnanexus_project" \
#     "260518_docker_images_manifestov2"
#
#   ./repackage_image.sh \
#     "quay.io/ucsc_cgl/rnaseq-cgl-pipeline@sha256:785eee9f750ab91078d84d1ee779b6f74717eafc09e49da817af6b87619b0756" \
#     "rnaseq_cgl_pipeline:1.0-oci" \
#     "my_dnanexus_project" \
#     "260518_docker_images_manifestov2"
# =============================================================================
# ---------------------------------------------------------------------------
# validate_args <argc>
#   Ensures exactly 4 arguments were passed to the script.
#   Call as: validate_args $#
# ---------------------------------------------------------------------------
validate_args() {
  local argc="$1"
  if [[ "$argc" -ne 4 ]]; then
    echo "Error: exactly 4 arguments required." >&2
    echo "" >&2
    echo "Usage: $0 <old_image> <new_image> <dx_project> <dx_dest_folder>" >&2
    echo "" >&2
    echo "  old_image       full source image ref (tag or sha256)" >&2
    echo "  new_image       target name:tag for the rebuilt OCI image" >&2
    echo "  dx_project      DNAnexus project name or ID" >&2
    echo "  dx_dest_folder  destination folder inside the DNAnexus project" >&2
    exit 1
  fi
}
# ---------------------------------------------------------------------------
# derive_names <old_image> <new_image>
#   Sets globals: BASE_NAME, WORK_DIR, TAR_FILE, OUT_FILE, LOAD_TAG
# ---------------------------------------------------------------------------
derive_names() {
  local old_image="$1"
  local new_image="$2"
  BASE_NAME="${new_image//[:\/]/_}"
  WORK_DIR="${BASE_NAME}"
  TAR_FILE="${BASE_NAME}.tar"
  OUT_FILE="${BASE_NAME}.tar.gz"
  # sha256-pinned images carry no usable tag — fall back to new image name
  if [[ "$old_image" == *@sha256:* ]]; then
    LOAD_TAG="$new_image"
  else
    LOAD_TAG="${old_image##*/}"   # strip registry + org prefix
  fi
}
# ---------------------------------------------------------------------------
# print_summary <old_image> <new_image> <dx_project> <dx_dest_folder>
# ---------------------------------------------------------------------------
print_summary() {
  local old_image="$1"
  local new_image="$2"
  local dx_project="$3"
  local dx_dest_folder="$4"
  echo ""
  echo "======================================================================"
  echo " old image      : $old_image"
  echo " new image      : $new_image"
  echo " load tag       : $LOAD_TAG"
  echo " work dir       : $WORK_DIR/"
  echo " output         : $OUT_FILE"
  echo " dx project     : $dx_project"
  echo " dx dest folder : $dx_dest_folder"
  echo "======================================================================"
}
# ---------------------------------------------------------------------------
# pull_image <old_image>
#   Pulls the source image to a local docker-archive tar via skopeo.
# ---------------------------------------------------------------------------
pull_image() {
  local old_image="$1"
  echo "[1/6] Pulling image via skopeo..."
  mkdir -p "$WORK_DIR" && cd "$WORK_DIR"
  skopeo copy \
    "docker://${old_image}" \
    "docker-archive:${TAR_FILE}:${LOAD_TAG}"
}
# ---------------------------------------------------------------------------
# load_image
#   Loads the tar archive into the Docker daemon.
# ---------------------------------------------------------------------------
load_image() {
  echo "[2/6] Loading image into Docker..."
  docker load -i "$TAR_FILE"
}
# ---------------------------------------------------------------------------
# write_dockerfile
#   Writes a minimal Dockerfile that stamps the OCI label.
# ---------------------------------------------------------------------------
write_dockerfile() {
  echo "[3/6] Writing Dockerfile..."
  cat <<EOF > Dockerfile
FROM ${LOAD_TAG}
LABEL original_manifest="v1_legacy"
EOF
}
# ---------------------------------------------------------------------------
# build_oci_image <new_image>
#   Rebuilds the image with OCI-compliant media types.
# ---------------------------------------------------------------------------
build_oci_image() {
  local new_image="$1"
  echo "[4/6] Building OCI-compliant image..."
  docker buildx build \
    --output type=docker,oci-mediatypes=true \
    -t "${new_image}" .
}
# ---------------------------------------------------------------------------
# save_image <new_image>
#   Saves the rebuilt image as a compressed tarball.
# ---------------------------------------------------------------------------
save_image() {
  local new_image="$1"
  echo "[5/6] Saving image to ${OUT_FILE}..."
  docker save "${new_image}" | gzip > "$OUT_FILE"
}
# ---------------------------------------------------------------------------
# upload_to_dnanexus <dx_project> <dx_dest_folder>
#   Selects the DNAnexus project and uploads the tarball.
# ---------------------------------------------------------------------------
upload_to_dnanexus() {
  local dx_project="$1"
  local dx_dest_folder="$2"
  echo "[6/6] Uploading to DNAnexus..."
  dx select "$dx_project"
  dx mkdir -p "$dx_dest_folder"
  dx upload --path "${DX_PROJECT_CONTEXT_ID}:/${dx_dest_folder}/" \
    "$OUT_FILE" --brief
}
# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  validate_args $#
  local old_image="$1"
  local new_image="$2"
  local dx_project="$3"
  local dx_dest_folder="$4"
  derive_names     "$old_image" "$new_image"
  print_summary    "$old_image" "$new_image" "$dx_project" "$dx_dest_folder"
  pull_image       "$old_image"
  load_image
  write_dockerfile
  build_oci_image  "$new_image"
  save_image       "$new_image"
  upload_to_dnanexus "$dx_project" "$dx_dest_folder"
  echo ""
  echo "Done. ${new_image} uploaded to ${dx_project}:/${dx_dest_folder}/${OUT_FILE}"
}
main "$@"