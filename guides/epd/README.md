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
| Model              | [Qwen/Qwen3-VL-2B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct) |
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
| NVIDIA GPU (SGLang) | `modelserver/gpu/sglang/${INFRA_PROVIDER}/`  | SGLang inference server (`INFRA_PROVIDER` options: `base`, `gke`)                    |
| AMD GPU             | `modelserver/amd/vllm/`    | AMD GPU                                    |
| AMD GPU (SGLang)    | `modelserver/amd/sglang`   | AMD GPU                                    |
| Intel XPU           | `modelserver/xpu/vllm/`    | Intel Data Center GPU Max 1550+            |
| Intel Gaudi (HPU)   | `modelserver/hpu/vllm/`    | Gaudi 1/2/3 with DRA support               |
| Google TPU v6e      | `modelserver/tpu-v6/vllm/` | GKE TPU                                    |
| Google TPU v7       | `modelserver/tpu-v7/vllm/` | GKE TPU                                    |
| CPU                 | `modelserver/cpu/vllm/`    | Intel/AMD, 64 cores + 64GB RAM per replica |

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
    export GUIDE_NAME="epd"
    export NAMESPACE=llm-d-epd
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
> The manifest pins `storageClassName: ibm-spectrum-scale-fileset`, which is specific to the environment this guide was authored on. **Edit `guides/epd/model-cache-pvc.yaml` to use an RWX-capable StorageClass available in your cluster** (e.g. NFS, CephFS, EFS, Azure Files, GCP Filestore) before applying. If your cluster's default StorageClass is RWX-capable, you can remove the `storageClassName` field entirely.

```bash
kubectl apply -n ${NAMESPACE} -f guides/${GUIDE_NAME}/model-cache-pvc.yaml
```

> [!NOTE]
> The first model server pod to start will populate the cache via HuggingFace Hub; subsequent pods reuse it. HF Hub uses lock files to serialize concurrent downloads, but expect the first cold start to be longer than the others.

### 3. Deploy the multimedia downloader (caching proxy)

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

### 1. Get the IP of a Proxy

Each role has its own EPP service. Pick the role you want to send traffic to (`decode` is the typical entry point for completion requests):

**Standalone Mode**

```bash
export ROLE=decode # encode | prefill | decode
export IP=$(kubectl get service ${GUIDE_NAME}-${ROLE}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
```

<details>
<summary> <b>Gateway Mode</b> </summary>

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
```

</details>

### 2. Send Test Requests

**Open a temporary interactive shell inside the cluster:**

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --env="IP=$IP" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash
```

**Send a completion request:**

```bash
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "Qwen/Qwen3-VL-2B-Instruct",
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
