# EPD (Encode / Prefill / Decode)

## Overview

This guide deploys an **Encode / Prefill / Decode (EPD)** topology for vLLM and SGLang model servers. Three independent llm-d Router instances are installed — one per role — each fronting its own InferencePool of a single model server replica.

The result:

- **3 Endpoint Pickers (EPPs)** — one for `encode`, one for `prefill`, one for `decode`.
- **3 InferencePools** — selecting model servers by `llm-d.ai/role`.
- **1 vLLM (or SGLang) replica per pool** — three model servers in total.

## Default Configuration

| Parameter          | Value                                                   |
| ------------------ | ------------------------------------------------------- |
| Model              | [openai/gpt-oss-120b](https://huggingface.co/openai/gpt-oss-120b) |
| Roles              | encode, prefill, decode                                 |
| Replicas per role  | 1                                                       |
| Tensor Parallelism | 2                                                       |
| GPUs per replica   | 2                                                       |
| Total GPUs         | 6                                                       |

### Supported Hardware Backends

This guide includes configurations for the following accelerators:

| Backend             | Directory                  | Notes                                      |
| ------------------- | -------------------------- | ------------------------------------------ |
| NVIDIA GPU          | `modelserver/gpu/vllm/${INFRA_PROVIDER}/`    | Default configuration (`INFRA_PROVIDER` options: `base`, `gke`)                      |

> [!NOTE]
> Some hardware variants use reduced configurations (smaller models) to enable CI testing for compatibility and regression checks. These configurations are maintained by their respective hardware vendors and are not guaranteed as production-ready examples. Users deploying on non-default hardware should review and adjust the configurations for their environment.

## Prerequisites

- Have the [proper client tools installed on your local system](../../helpers/client-setup/README.md) to use this guide.
- Checkout llm-d repo:

  ```bash
    export branch="main" # branch, tag, or commit hash
    git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}
  ```

- Set the following environment variables:

  ```bash
    export GAIE_VERSION=v1.5.0
    export ROUTER_CHART_VERSION=v0
    export GUIDE_NAME="coordinator-epd"
    export NAMESPACE=llm-d-coordinator-epd
  ```

- Install the Gateway API Inference Extension CRDs:

  ```bash
    kubectl apply -k "https://github.com/kubernetes-sigs/gateway-api-inference-extension/config/crd?ref=${GAIE_VERSION}"
  ```

- Create a target namespace for the installation

  ```bash
      kubectl create namespace ${NAMESPACE}
  ```

## Installation Instructions

> [!NOTE]
> The steps below deploy the full **EPD** topology. For a **PD-only** deployment (no `encode` role), skip the encode-specific parts:
>
> - Step 1: drop `encode` from the `for ROLE in ...` loop (deploy only `prefill` and `decode` routers).
> - Step 3: skip entirely — the multimedia downloader is only used by the encode/coordinator pipeline.
> - Step 4: apply a PD-only modelserver overlay (encode modelserver not needed).
> - Step 5: in the coordinator configuration, keep only the `conditional-decode`, `prefill`, and `decode` steps (drop `replace-media-urls`, `render`, and `encode`).

### 1. Deploy the llm-d Routers (one per role)

Each role gets its own llm-d Router release, EPP, and InferencePool. Install all three in [Standalone Mode](placeholder-link):

```bash
# Assuming base-directory is the root of the llm-d repo
for ROLE in encode prefill decode; do
  helm install ${GUIDE_NAME}-${ROLE} \
      oci://ghcr.io/llm-d/charts/llm-d-router-standalone-dev \
      -f guides/recipes/router/base.values.yaml \
      -f guides/${GUIDE_NAME}/router/${GUIDE_NAME}-${ROLE}.values.yaml \
      -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
done
```

<details>
<summary><h4>Gateway Mode</h4></summary>

To use a Kubernetes Gateway managed proxy rather than the standalone version, follow these steps instead of applying the previous Helm chart:

1. _Deploy a Kubernetes Gateway_ named by following one of [the gateway guides](../prereq/gateways).
2. _Deploy each role's llm-d router and an HTTPRoute_ that connects it to the Gateway as follows:

```bash
export PROVIDER_NAME=gke # options: none, gke, agentgateway, istio
for ROLE in encode prefill decode; do
  helm install ${GUIDE_NAME}-${ROLE} \
      oci://ghcr.io/llm-d/charts/llm-d-router-gateway-dev  \
      -f guides/recipes/router/base.values.yaml \
      -f guides/${GUIDE_NAME}/router/${GUIDE_NAME}-${ROLE}.values.yaml \
      --set provider.name=${PROVIDER_NAME} \
      --set httpRoute.create=true \
      --set httpRoute.inferenceGatewayName=llm-d-inference-gateway \
      -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
done
```

</details>

### 2. Provision the shared model cache

The three model server pods and the coordinator share a single `PersistentVolumeClaim` (`llm-d-model-cache`) for the HuggingFace model files, so the model is downloaded once and reused. The claim is `ReadWriteMany` and 250Gi.

> [!IMPORTANT]
> The manifest pins `storageClassName: ibm-spectrum-scale-fileset`, which is specific to the environment this guide was authored on. **Edit `guides/coordinator-epd/model-cache-pvc.yaml` to use an RWX-capable StorageClass available in your cluster** (e.g. NFS, CephFS, EFS, Azure Files, GCP Filestore) before applying. If your cluster's default StorageClass is RWX-capable, you can remove the `storageClassName` field entirely.

```bash
kubectl apply -n ${NAMESPACE} -f guides/${GUIDE_NAME}/model-cache-pvc.yaml
```

> [!NOTE]
> The first model server pod to start will populate the cache via HuggingFace Hub; subsequent pods reuse it. HF Hub uses lock files to serialize concurrent downloads, but expect the first cold start to be longer than the others.

### 3. (Optional) Deploy the multimedia downloader (caching proxy)

The coordinator's `replace-media-urls` step routes through an in-cluster Squid proxy that caches origin images/video, eliminating redundant fetches across requests.

To cache HTTPS origins, Squid must terminate TLS and re-sign responses with its own CA (SSL-Bump). A single script clones the `mm_service-guides` branch, deploys the SSL-Bump Squid (prebuilt image + generated CA secret), applies the coordinator CA patch, and restarts the coordinator:

```bash
./multimedia-downloader/setup-ssl-bump.sh
```

### 4. Deploy the Model Servers

Apply the Kustomize overlay for your specific backend (defaulting to NVIDIA GPU / vLLM). One overlay deploys all three role-specific model servers (encode, prefill, decode), each as a single replica:

```bash
export INFRA_PROVIDER=base # base | gke
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}/
```

<details>
<summary><h4>Other Accelerators</h4></summary>

```bash
# AMD GPU
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/amd/vllm/

# Intel XPU
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/xpu/vllm/

# Intel Gaudi (HPU)
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/hpu/vllm/

# Google TPU v6e
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/tpu-v6/vllm/

# Google TPU v7
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/tpu-v7/vllm/

# CPU
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/cpu/vllm/
```

</details>

### 5. Deploy the Coordinator

Drives the multimodal `replace-media-urls → render → encode → prefill → decode` pipeline. The configmap references `${NAMESPACE}` and `${PROVIDER_NAME}`, so build with kustomize and pipe through `envsubst` before applying:

```bash
kustomize build guides/${GUIDE_NAME}/coordinator/ | envsubst | kubectl apply -n ${NAMESPACE} -f -
```

### 6. (Optional) Enable monitoring

> [!NOTE]
> GKE provides [automatic application monitoring](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/configure-automatic-application-monitoring) out of the box. The llm-d [Monitoring stack](../../docs/monitoring/README.md) is not required for GKE, but it is available if you prefer to use it.

- Install the [Monitoring stack](../../docs/monitoring/README.md).
- Deploy the monitoring resources for this guide.

```bash
kubectl apply -n ${NAMESPACE} -k guides/recipes/modelserver/components/monitoring
```

## Verification

### 1. Get the IP of the Entrypoint

Clients always send requests to the **coordinator**, which orchestrates the `encode → prefill → decode` pipeline. The per-role EPPs are internal — the coordinator dispatches to them by setting the `EPP-Phase` header on its outbound calls.

**Standalone Mode**

Hit the coordinator's ClusterIP directly:

```bash
export IP=$(kubectl get service llm-d-coordinator -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
export PORT=8080
```

<details>
<summary> <b>Gateway Mode</b> </summary>

The Gateway forwards client traffic (no `EPP-Phase` header) to the coordinator via the `coordinator` HTTPRoute deployed alongside the coordinator overlay. Per-phase routes still match coordinator-issued internal calls.

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
export PORT=80
```

</details>

### 2. Send Test Requests

**Open a temporary interactive shell inside the cluster:**

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="PORT=$PORT" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash
```

**Send a completion request:**

```bash
curl -X POST http://${IP}:${PORT}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "openai/gpt-oss-120b",
        "prompt": "How are you today?"
    }' | jq
```

## Cleanup

To remove the deployed components:

```bash
for ROLE in encode prefill decode; do
  helm uninstall ${GUIDE_NAME}-${ROLE} -n ${NAMESPACE}
done
kustomize build guides/${GUIDE_NAME}/coordinator/ | envsubst | kubectl delete -n ${NAMESPACE} -f -
kubectl delete -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}
kubectl delete -n ${NAMESPACE} -k guides/${GUIDE_NAME}/multimedia-downloader
kubectl delete -n ${NAMESPACE} -f guides/${GUIDE_NAME}/model-cache-pvc.yaml
kubectl delete namespace ${NAMESPACE}
```
