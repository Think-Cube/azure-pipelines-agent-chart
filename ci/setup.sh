#!/usr/bin/env bash
# Installs KEDA into the kind cluster, so the chart's ScaledJob and TriggerAuthentication can be created.
set -euo pipefail

helm repo add kedacore https://kedacore.github.io/charts
helm install keda kedacore/keda \
  --version 2.21.1 \
  --namespace keda --create-namespace \
  --wait --timeout 5m
kubectl get crd scaledjobs.keda.sh triggerauthentications.keda.sh
