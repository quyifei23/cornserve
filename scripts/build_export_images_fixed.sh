#!/usr/bin/env bash

# Usage:
#
#     export REGISTRY=see-below-for-local-vs-distributed
#     bash scripts/build_export_images_fixed.sh [service1 service2 ...]
#
# If no services are specified, it builds all services found in the docker/ directory except for `dev`.
#
# The `REGISTRY` environment variable:
# - If set to `local`, it builds the images directly within the local k3s containerd.
# - If set to `none`, it just builds the images with Docker without exporting them to anywhere.
# - If set to `minikube`, it builds the images with Docker and loads them into Minikube.
# - If set to a URL (e.g., `localhost:30070`), it builds the images with Docker and pushes them to that registry.
# More details: https://cornserve.ai/contributor_guide/kubernetes/

set -euo pipefail

NAMESPACE="cornserve"

# 增加系统限制避免 BrokenPipeError
ulimit -n 65536 2>/dev/null || true
ulimit -u 65536 2>/dev/null || true

source .venv/bin/activate
export REGISTRY="local"
# Ensure the REGISTRY environment variable is set.
if [ -z "${REGISTRY:-}" ]; then
  echo "The REGISTRY environment variable is not set."
  echo "The REGISTRY environment variable:"
  echo "- If set to 'local', it builds the images directly within the local k3s containerd."
  echo "- If set to 'none', it just builds the images with Docker without exporting them to anywhere."
  echo "- If set to 'minikube', it builds the images with Docker and loads them into Minikube."
  echo "- If set to a URL (e.g., 'localhost:30070'), it builds the images with Docker and pushes them to that registry."
  echo "More details: https://cornserve.ai/contributor_guide/kubernetes/"
  exit 1
fi

# Get the user to type their password if they want local k3s containerd export
if [[ "${REGISTRY}" == "local" ]]; then
  # Set k3s containerd socket
  K3S_CONTAINERD_SOCK="unix:///run/k3s/containerd/containerd.sock"
  export CONTAINERD_ADDRESS="${CONTAINERD_ADDRESS:-$K3S_CONTAINERD_SOCK}"

  # Ensure k3s is installed and list existing images
  echo "Building image directly within local k3s containerd"
  k3s_bin="$(which k3s)"
  sudo "${k3s_bin}" ctr images ls | grep -i "${NAMESPACE}" || true

  # Ensure nerdctl is installed
  if ! command -v nerdctl &> /dev/null; then
    echo "nerdctl is not installed. Please install it to build images for local k3s containerd."
    exit 1
  fi

  # Ensure buildkit is configured
  nerdctl_output=$(sudo --preserve-env=CONTAINERD_ADDRESS nerdctl --namespace k8s.io build 2>&1 || true)
  if echo "${nerdctl_output}" | grep -q "buildkit"; then
    echo "It seems like buildkit is not configured. Please configure it to build images for local k3s containerd."
    echo "Nerdctl output:"
    echo "${nerdctl_output}"
    exit 1
  fi

  # 清理旧的构建缓存
  echo "Cleaning up old build cache..."
  sudo --preserve-env=CONTAINERD_ADDRESS nerdctl --namespace k8s.io builder prune -f 2>/dev/null || true
fi

# If service names are provided as arguments, use them.
# Otherwise, find all Dockerfiles in the "docker" directory.
if [ "$#" -ge 1 ]; then
  BUILD_LIST=("$@")
else
  echo "Building all services found in the docker directory."
  BUILD_LIST=()
  while IFS= read -r file; do
    if [[ -f "$file" ]]; then
      service=$(basename "$file" .Dockerfile)
      if [[ "$service" != "dev" ]]; then
        BUILD_LIST+=("$service")
      fi
    fi
  done < <(find docker -type f -name '*.Dockerfile')
fi

echo "Building services: ${BUILD_LIST[@]}"
echo "Total services to build: ${#BUILD_LIST[@]}"
sleep 2

# Generate protobuf Python bindings
if [ -f scripts/generate_pb.sh ]; then
  echo "Generating protobuf Python bindings..."
  bash scripts/generate_pb.sh
fi

# nerdctl wrapper to ensure correct containerd socket and namespace
nerdctl() {
  command sudo --preserve-env=CONTAINERD_ADDRESS nerdctl --namespace k8s.io "$@"
}

# Function to build and export the image for a single service
build_and_export() {
  local SERVICE="$1"
  local MAX_RETRIES=2
  local RETRY_COUNT=0

  echo "========================================="
  echo "Building service: ${SERVICE}"
  echo "========================================="

  DOCKERFILE=$(find docker -type f -name "${SERVICE}.Dockerfile" | head -n 1)
  if [[ -z "${DOCKERFILE}" ]]; then
    echo "Warning: Dockerfile for ${SERVICE} not found. Skipping."
    return 1
  fi

  IMAGE="${NAMESPACE}/${SERVICE}:latest"
  PUSH_IMAGE="${REGISTRY}/${NAMESPACE}/${SERVICE}:latest"

  while [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; do
    echo "Attempt $((RETRY_COUNT + 1))/${MAX_RETRIES} for ${SERVICE}"

    local build_success=false

    if [[ "${REGISTRY}" == "local" ]]; then
      echo "Building image directly within local k3s containerd..."
      # 删除旧镜像避免冲突
      nerdctl rmi -f "${IMAGE}" 2>/dev/null || true

      # 构建命令（已移除 --network=host 以避免权限错误）
      if nerdctl build \
        --progress=plain \
        -f "${DOCKERFILE}" \
        -t "${IMAGE}" \
        . 2>&1; then
        build_success=true
      fi
    elif [[ "${REGISTRY}" == "none" ]]; then
      echo "Building image with Docker (no export)..."
      docker rmi -f "${IMAGE}" 2>/dev/null || true

      if docker build \
        --progress=plain \
        -f "${DOCKERFILE}" \
        -t "${IMAGE}" \
        . 2>&1; then
        build_success=true
      fi
    elif [[ "${REGISTRY}" == "minikube" ]]; then
      echo "Building image with Docker for Minikube..."
      docker rmi -f "${IMAGE}" 2>/dev/null || true

      if docker build \
        --progress=plain \
        -f "${DOCKERFILE}" \
        -t "${IMAGE}" \
        . 2>&1; then
        echo "Loading ${IMAGE} into Minikube..."
        minikube image load "${IMAGE}"
        build_success=true
      fi
    else
      echo "Building image with Docker and pushing to ${REGISTRY}..."
      docker rmi -f "${PUSH_IMAGE}" 2>/dev/null || true

      if docker build \
        --progress=plain \
        -f "${DOCKERFILE}" \
        -t "${PUSH_IMAGE}" \
        . 2>&1; then
        echo "Pushing ${PUSH_IMAGE} to registry..."
        docker push "${PUSH_IMAGE}"
        build_success=true
      fi
    fi

    if [ "${build_success}" = true ]; then
      echo "✅ Successfully built ${IMAGE}"
      return 0
    fi

    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ ${RETRY_COUNT} -lt ${MAX_RETRIES} ]; then
      echo "⚠️  Build failed for ${SERVICE}, retrying in 10 seconds..."
      sleep 10
    fi
  done

  echo "❌ Failed to build ${SERVICE} after ${MAX_RETRIES} attempts"
  return 1
}

# 串行构建所有服务（避免 BrokenPipeError）
FAILED_SERVICES=()
for SERVICE in "${BUILD_LIST[@]}"; do
  if ! build_and_export "${SERVICE}"; then
    FAILED_SERVICES+=("${SERVICE}")
  fi

  # 构建间隔，避免系统过载
  sleep 2
done

# 输出构建结果汇总
echo ""
echo "========================================="
echo "Build Summary"
echo "========================================="
echo "Total services: ${#BUILD_LIST[@]}"
echo "✅ Successfully built: $((${#BUILD_LIST[@]} - ${#FAILED_SERVICES[@]}))"
if [ ${#FAILED_SERVICES[@]} -gt 0 ]; then
  echo "❌ Failed services: ${FAILED_SERVICES[@]}"
  echo ""
  echo "You can retry failed services individually with:"
  for SERVICE in "${FAILED_SERVICES[@]}"; do
    echo "  export REGISTRY=${REGISTRY}"
    echo "  bash scripts/build_export_images_fixed.sh ${SERVICE}"
  done
  exit 1
else
  echo "✅ All services built successfully!"
  exit 0
fi
