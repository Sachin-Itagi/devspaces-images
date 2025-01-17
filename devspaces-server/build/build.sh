#!/bin/bash
#
# Copyright (c) 2017-2023 Red Hat, Inc.
# This program and the accompanying materials are made
# available under the terms of the Eclipse Public License 2.0
# which is available at https://www.eclipse.org/legal/epl-2.0/
#
# SPDX-License-Identifier: EPL-2.0
#

set -e
set -u

IMAGE_ALIASES=${IMAGE_ALIASES:-}
ERROR=${ERROR:-}
DIR=${DIR:-}
SHA_TAG=${SHA_TAG:-}

skip_tests() {
  if [ $SKIP_TESTS = "true" ]; then
    return 0
  else
    return 1
  fi
}

prepare_build_args() {
    IFS=',' read -r -a BUILD_ARGS_ARRAY <<< "$@"
    for i in ${BUILD_ARGS_ARRAY[@]}; do
    BUILD_ARGS+="--build-arg $i "
    done
}

init() {
  BLUE='\033[1;34m'
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  BROWN='\033[0;33m'
  PURPLE='\033[0;35m'
  NC='\033[0m'
  BOLD='\033[1m'
  UNDERLINE='\033[4m'

  ORGANIZATION="quay.io/eclipse"
  PREFIX="che"
  TAG="next"
  SKIP_TESTS=false
  NAME="che"
  ARGS=""
  OPTIONS=""
  DOCKERFILE=""
  BUILD_ARGS=""

  while [ $# -gt 0 ]; do
    case $1 in
      --*)
        OPTIONS="${OPTIONS} ${1}"
        ;;
      *)
        ARGS="${ARGS} ${1}"
        ;;
    esac

    case $1 in
      --tag:*)
        TAG="${1#*:}"
        shift ;;
      --organization:*)
        ORGANIZATION="${1#*:}"
        shift ;;
      --prefix:*)
        PREFIX="${1#*:}"
        shift ;;
      --name:*)
        NAME="${1#*:}"
        shift ;;
      --skip-tests)
        SKIP_TESTS=true
        shift ;;
      --sha-tag)
        SHA_TAG=$(git rev-parse --short HEAD)
        shift ;;
      --dockerfile:*)
        DOCKERFILE="${1#*:}"
        shift ;;
      --build-arg*:*)
        BUILD_ARGS_CSV="${1#*:}"
        prepare_build_args $BUILD_ARGS_CSV
        shift ;;
      --*)
        printf "${RED}Unknown parameter: $1${NC}\n"; exit 2 ;;
      *)
       shift;;
    esac
  done

  IMAGE_NAME="$ORGANIZATION/$PREFIX-$NAME:$TAG"
}

build() {

  # Compute directory
  if [ -z $DIR ]; then
      DIR=$(cd "$(dirname "$0")"; pwd)
  fi

  # If Dockerfile is empty, build all Dockerfiles
  if [ -z ${DOCKERFILE} ]; then
    DOCKERFILES_TO_BUILD="$(ls ${DIR}/Dockerfile*)"
    ORIGINAL_TAG=${TAG}
    # Build image for each Dockerfile
    for dockerfile in ${DOCKERFILES_TO_BUILD}; do
       dockerfile=$(basename $dockerfile)
       # extract TAG from Dockerfile
       if [ ${dockerfile} != "Dockerfile" ]; then
         TAG=${ORIGINAL_TAG}-$(echo ${dockerfile} | sed -e "s/^Dockerfile.//")
       fi
       IMAGE_NAME="$ORGANIZATION/$PREFIX-$NAME:$TAG"
       DOCKERFILE=${dockerfile}
       build_image
    done

    # restore variables
    TAG=${ORIGINAL_TAG}
    IMAGE_NAME="$ORGANIZATION/$PREFIX-$NAME:$TAG"
  else
    # else if specified, build only the one specified
    build_image
  fi

}

build_image() {
  printf "${BOLD}Building Docker Image ${IMAGE_NAME} from $DIR directory with tag $TAG${NC}\n"
  # Replace macros in Dockerfiles
  cat ${DIR}/${DOCKERFILE} | sed \
    -e "s;\${BUILD_ORGANIZATION};${ORGANIZATION};" \
    -e "s;\${BUILD_PREFIX};${PREFIX};" \
    -e "s;\${BUILD_TAG};${TAG};" \
    > ${DIR}/.Dockerfile
  cd "${DIR}" && docker build -f ${DIR}/.Dockerfile -t ${IMAGE_NAME} ${BUILD_ARGS} .
  DOCKER_BUILD_STATUS=$?
  rm ${DIR}/.Dockerfile
  if [ $DOCKER_BUILD_STATUS -eq 0 ]; then
    printf "Build of ${BLUE}${IMAGE_NAME} ${GREEN}[OK]${NC}\n"
    if [ ! -z "${SHA_TAG}" ]; then
      SHA_IMAGE_NAME=${ORGANIZATION}/${PREFIX}-${NAME}:${SHA_TAG}
      docker tag ${IMAGE_NAME} ${SHA_IMAGE_NAME}
      DOCKER_TAG_STATUS=$?
      if [ $DOCKER_TAG_STATUS -eq 0 ]; then
        printf "Re-tagging with SHA based tag ${BLUE}${SHA_IMAGE_NAME} ${GREEN}[OK]${NC}\n"
      else
        printf "${RED}Failure when tagging docker image ${SHA_IMAGE_NAME}${NC}\n"
        exit 1
      fi
    fi
    if [ ! -z "${IMAGE_ALIASES}" ]; then
      for TMP_IMAGE_NAME in ${IMAGE_ALIASES}
      do
        docker tag ${IMAGE_NAME} ${TMP_IMAGE_NAME}:${TAG}
        DOCKER_TAG_STATUS=$?
        if [ $DOCKER_TAG_STATUS -eq 0 ]; then
          printf "  /alias ${BLUE}${TMP_IMAGE_NAME}:${TAG}${NC} ${GREEN}[OK]${NC}\n"
        else
          printf "${RED}Failure when building docker image ${IMAGE_NAME}${NC}\n"
          exit 1
        fi

      done
    fi
    printf "${GREEN}Script run successfully: ${BLUE}${IMAGE_NAME}${NC}\n"
  else
    printf "${RED}Failure when building docker image ${IMAGE_NAME}${NC}\n"
    exit 1
  fi
}

check_docker() {
  if ! docker ps > /dev/null 2>&1; then
    output=$(docker ps)
    printf "${RED}Docker not installed properly: ${output}${NC}\n"
    exit 1
  fi
}

docker_exec() {
  if has_docker_for_windows_client; then
    MSYS_NO_PATHCONV=1 docker.exe "$@"
  else
    "$(which docker)" "$@"
  fi
}

has_docker_for_windows_client() {
  GLOBAL_HOST_ARCH=$(docker version --format {{.Client}})

  if [[ "${GLOBAL_HOST_ARCH}" = *"windows"* ]]; then
    return 0
  else
    return 1
  fi
}

get_full_path() {
  echo "$(cd "$(dirname "${1}")"; pwd)/$(basename "$1")"
}

convert_windows_to_posix() {
  echo "/"$(echo "$1" | sed 's/\\/\//g' | sed 's/://')
}

get_clean_path() {
  INPUT_PATH=$1
  # \some\path => /some/path
  OUTPUT_PATH=$(echo ${INPUT_PATH} | tr '\\' '/')
  # /somepath/ => /somepath
  OUTPUT_PATH=${OUTPUT_PATH%/}
  # /some//path => /some/path
  OUTPUT_PATH=$(echo ${OUTPUT_PATH} | tr -s '/')
  # "/some/path" => /some/path
  OUTPUT_PATH=${OUTPUT_PATH//\"}
  echo ${OUTPUT_PATH}
}

get_mount_path() {
  FULL_PATH=$(get_full_path "${1}")
  POSIX_PATH=$(convert_windows_to_posix "${FULL_PATH}")
  CLEAN_PATH=$(get_clean_path "${POSIX_PATH}")
  echo $CLEAN_PATH
}

# grab assembly
DIR="$(cd "$(dirname "$0")"; pwd)/dockerfiles"
if [ ! -d "${DIR}/../../assembly/assembly-main/target" ]; then
  echo "${ERROR}Have you built assembly/assemby-main in ${DIR}/../assembly/assembly-main 'mvn clean install'?"
  exit 2
fi

# Use of folder
BUILD_ASSEMBLY_DIR=$(echo "${DIR}"/../../assembly/assembly-main/target/eclipse-che-*/eclipse-che-*/)
LOCAL_ASSEMBLY_DIR="${DIR}"/eclipse-che

if [ -d "${LOCAL_ASSEMBLY_DIR}" ]; then
  rm -r "${LOCAL_ASSEMBLY_DIR}"
fi

echo "Copying assembly ${BUILD_ASSEMBLY_DIR} --> ${LOCAL_ASSEMBLY_DIR}"
cp -r "${BUILD_ASSEMBLY_DIR}" "${LOCAL_ASSEMBLY_DIR}"

init --name:server "$@"
build

#cleanUp
rm -rf ${DIR}/eclipse-che
