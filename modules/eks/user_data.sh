#!/bin/bash
set -o xtrace

# Bootstrap and join the cluster
/etc/eks/bootstrap.sh ${cluster_name} \
  --b64-cluster-ca ${cluster_ca} \
  --apiserver-endpoint ${cluster_endpoint} \
  --kubelet-extra-args '--max-pods=110'

# Additional user data
${additional_userdata}