#!/bin/bash

set -e

cd ${GOPATH}/src/github.com/pachyderm/pachyderm

function die {
  echo "error: $1" >2
  exit 1
}
export -f die

# get_images builds or download pachd and worker images
function get_images {
  if [[ "${PACH_VERSION}" = local ]]; then
    make install || die "could not build pachctl"
    make docker-build || die "could not build pachd/worker"
  else
    for i in pachd worker; do
      echo docker pull pachyderm/${i}:${PACH_VERSION}
      docker pull pachyderm/${i}:${PACH_VERSION}
    done
  fi
}
export -f get_images

## If the caller provided a tag, build and use that
export PACH_VERSION=local
MINIKUBE_FLAGS=()
eval "set -- $( getopt -l "tag:,cpus:,memory:" "--" "${0}" "${@:-}" )"
while true; do
  case "${1}" in
    --cpus)
      MINIKUBE_FLAGS+=(--cpus=${2})
      shift 2
      ;;
    --memory)
      MINIKUBE_FLAGS+=(--memory=${2})
      shift 2
      ;;
    --tag)
      export PACH_VERSION=${2##v}  # remove "v" prefix, e.g. v1.7.0
      shift 2
      ;;
    --)
      shift
      break
      ;;
  esac
done

etcd_image="quay.io/coreos/etcd:v3.3.5"
if ! docker images | grep -q "${etcd_image}"; then
  echo -e "\nMissing \"${etcd_image}\", please run:\ndocker pull ${etcd_image}\n"
  exit 1
fi

# In parallel, start minikube, build pachctl, and get/build the pachd and worker images
cat <<EOF
Running:
  get_images
  minikube start ${MINIKUBE_FLAGS[@]}
EOF
cat <<EOF | tail -c+1 | xargs -d\\n -n1 -P3 -- /bin/bash -c
get_images
minikube start ${MINIKUBE_FLAGS[@]}
EOF

# Print a spinning wheel while waiting for minikube to come up
set +x
WHEEL="-\|/"
until minikube ip 2>/dev/null; do
    # advance wheel 1/4 turn
    WHEEL=${WHEEL:1}${WHEEL:0:1}
    # jump to beginning of line & print message
    echo -en "\e[G\e[K${WHEEL:0:1} waiting for minikube to start..."
    sleep 1
done
set -x

export ADDRESS=$(minikube ip):30650

# Push pachyderm images to minikube VM
etc/kube/push-to-minikube.sh pachyderm/pachd:${PACH_VERSION}
etc/kube/push-to-minikube.sh pachyderm/worker:${PACH_VERSION}
etc/kube/push-to-minikube.sh ${etcd_image}

# Deploy Pachyderm
if [[ "${PACH_VERSION}" = "local" ]]; then
  pachctl deploy local -d
else
  # deploy with -d (disable auth, small footprint), but use official version
  pachctl deploy local -d --dry-run | sed "s/:local/:${PACH_VERSION}/g" | kubectl create -f -
fi

# Wait for pachyderm to come up
set +x
until pachctl version; do
    # advance wheel 1/4 turn
    WHEEL=${WHEEL:1}${WHEEL:0:1}
    # jump to beginning of line & print message
    echo -en "\e[G\e[K${WHEEL:0:1} waiting for pachyderm to start..."
  sleep 1
done
set -x

# Kill pachctl port-forward and kubectl proxy
killall kubectl || true

# Port forward to etcd (for pfs/server/server_test.go)
export ETCD_POD=$(kubectl get pod -l suite=pachyderm,app=etcd -o jsonpath={.items[].metadata.name})
kubectl port-forward $ETCD_POD 32379:2379 &
