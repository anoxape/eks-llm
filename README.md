# EKS-LLM

A complete deployment to AWS EKS of [Triton Inference Server](https://github.com/triton-inference-server/server)
with [vLLM Backend](https://github.com/triton-inference-server/vllm_backend)
using [opt350m model](https://huggingface.co/facebook/opt-350m).

NB: This configuration is for a non-production environment.
Production deployments may require adjustments for security, scalability, and cost optimization.

## Requirements

- Hugging Face token
- AWS account
- AWS CLI authenticated in the AWS account
- Terraform ~> 1.9.4
- kubectl
- [Helmfile](https://github.com/helmfile/helmfile)
- make

## Run

### Configure

Copy [terraform/terraform.tfvars.example](terraform/terraform.tfvars.example) to `terraform/terraform.tfvars`:
```shell
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```
Modify `terraform/terraform.tfvars`

Copy [kubernetes/secrets.yaml.example](kubernetes/secrets.yaml.example) to `kubernetes/secrets.yaml`:
```shell
cp kubernetes/secrets.yaml.example kubernetes/secrets.yaml
```
Modify `kubernetes/secrets.yaml`

### Deploy

```shell
make
```

### Monitor

#### Kubectl

```shell
kubectl logs -n triton-client jobs/triton-client
```

#### Grafana

```shell
kubectl -n monitoring port-forward service/kube-prometheus-stack-grafana 8080:80
```
Open: http://localhost:8080

#### CloudWatch

Open CloudWatch / Logs in AWS Web Console
- Log group: `/aws/eks/eks-llm/workload`
- Log stream: `triton-client.triton-client-*`

### Re-run client job

```shell
make client
```

### Destroy

```shell
make destroy
```

## Design

Project structure:
- [`kubernetes/`](kubernetes/) (kubernetes resources)
- [`model_repository/`](model_repository/) (models)
- [`terraform/`](terraform/) (cloud infrastructure)
- [`Makefile`](Makefile) (entry point)

### Terraform

Resources:
- VPC: A virtual private cloud with private and public subnets across specified availability zones
- EKS Cluster: A managed EKS cluster with basic addons (coredns, eks-pod-identity-agent, kube-proxy, vpc-cni)
  - Node Groups: Two node groups with different configurations:
      - Core Group: 2 `m6i.large` instances for general workloads
      - GPU Group: 4 `g4dn.xlarge` instances with GPUs, labeled and tainted for exclusive use by pods requiring GPUs
- Fluent Bit:
    - A CloudWatch log group for collecting EKS workload logs
    - An IAM role for Fluent Bit Pods with access to the log group
    - An IAM policy for the role allowing specific actions on the log group
- Triton Server:
    - An S3 bucket for storing Triton Server resources
    - An IAM role for Triton Server pods with access to the S3 bucket
    - An IAM policy for the role allowing specific actions on the S3 bucket

Variables ([terraform/terraform.tfvars.example](terraform/terraform.tfvars.example)):
- `name`: The name for the EKS cluster and related resources
- `tags`: (Optional) Additional tags to be applied to resources
- `region`: The AWS region where the infrastructure will be deployed
- `azs`: A list of availability zones for the VPC
- `cidr`: The base CIDR block for the VPC

### Kubernetes

Module structure:
- [`kubernetes/helmfile.yaml`](kubernetes/helmfile.yaml)
    - defines Helm chart repositories, deployment options and dependencies
    - specifies the releases to be deployed
    - references values files for specific configurations of each release
- [`kubernetes/values/`](kubernetes/values/) files:
    - located in subdirectories corresponding to each Helm chart release
    - override values with specific configurations for the deployment
    - some values files reference:
        - terraform outputs expected in `kubernetes/terraform_output.json` file
        - secrets stored in a separate `kubernetes/secrets.yaml` file

Secrets ([kubernetes/secrets.yaml.example](kubernetes/secrets.yaml.example)):
- `grafana.adminPassword` - Grafana `admin` password
- `huggingface.token` - Hugging Face token

Components:
- [Triton Server](kubernetes/values/triton-server.yaml.gotmpl): A high-performance inference server for large language models (LLMs)
- [Triton Client](kubernetes/values/triton-client.yaml.gotmpl): A sample client validating Triton Server and running a performance test
- Monitoring Stack:
    - Prometheus: scrapes metrics from applications and stores them
    - Prometheus Adapter: enables scraping custom metrics from applications
    - Grafana: provides a web UI for visualizing metrics
    - Fluent Bit: a log aggregator that forwards logs to CloudWatch

### Triton Server

Kubernetes Controllers:
- `triton-server` (Deployment): NVIDIA Triton Server with vLLM backend
- `prefetch` (DaemonSet): This container, running as a DaemonSet on all GPU nodes,
  ensures the NVIDIA Triton Server image is pre-fetched locally for faster deployment.

Triton Server Pod:
- loads models from an S3 bucket location specified by Terraform output
- caches Hugging Face data on the host node using a hostPath volume (`/var/cache/huggingface`)
- uses a separate secret to store the Hugging Face authentication token

Horizontal Pod Autoscaler (HPA):
- scales the number of Triton Server replicas between 1 and 4 based on the `nv_inference_queue_duration_ms` metric
  (computed as average rate of the `nv_inference_queue_duration_us` metric over the past minute, converted to milliseconds
  by `prometheus-adapter`)
- aims for an average queue duration of 10 milliseconds
- scales down slowly (stabilization window 2 minutes) and scales up quickly (instantly)

### Triton Client

Kubernetes Job:
- automatically triggered on install/upgrade
- runs to completion and doesn't restart on failure
- runs two containers sequentially
    - `test` (initContainer)
    - `perf`

Test container:
- downloads and runs sample [client.py](https://raw.githubusercontent.com/triton-inference-server/vllm_backend/f064eed5af8baeff4d9f7679d8dc64eefe0e0229/samples/client.py)
- runs inference for a set of prompts [`kubernetes/values/triton-client-prompts.txt`](kubernetes/values/triton-client-prompts.txt)

Perf container:
- measures the performance of a Triton Server deployment using the [genai-perf](https://github.com/triton-inference-server/perf_analyzer/tree/main/genai-perf) tool
- runs `genai-perf` with several different concurrency variations

## Report

Report obtained from the test run of `triton-client` job log using:
```shell
make
kubectl logs -n triton-client jobs/triton-client
```

### Concurrency 8

Started with 1 replica.

```
genai-perf --model opt350m --backend vllm --service-kind triton --streaming --url triton-server.triton-server.svc:8001 --num-prompts 100 --random-seed 1 --synthetic-input-tokens-mean 128 --synthetic-input-tokens-stddev 0 --output-tokens-mean 1
28 --concurrency 8 --measurement-interval 30000
[INFO] genai_perf.wrapper:138 - Running Perf Analyzer : 'perf_analyzer -m opt350m --async --input-data artifacts/opt350m-triton-vllm-concurrency8/llm_inputs.json --service-kind triton -u triton-server.triton-server.svc:8001 --me
asurement-interval 30000 --stability-percentage 999 --profile-export-file artifacts/opt350m-triton-vllm-concurrency8/profile_export.json -i grpc --streaming --concurrency-range 8'
                                  LLM Metrics
┏━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━┓
┃                Statistic ┃    avg ┃    min ┃    max ┃   p99 ┃    p90 ┃   p75 ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━┩
│ Time to first token (ms) │  32.75 │  20.77 │  52.90 │ 46.98 │  39.78 │ 36.84 │
│ Inter token latency (ms) │  14.66 │  10.47 │ 113.04 │ 15.88 │  15.18 │ 14.85 │
│     Request latency (ms) │ 1,971… │  55.56 │ 2,175… │ 2,14… │ 2,082… │ 2,06… │
│   Output sequence length │ 135.52 │   2.00 │ 190.00 │ 154.… │ 148.00 │ 143.… │
│    Input sequence length │ 128.02 │ 128.00 │ 129.00 │ 129.… │ 128.00 │ 128.… │
└──────────────────────────┴────────┴────────┴────────┴───────┴────────┴───────┘
Output token throughput (per sec): 545.56
Request throughput (per sec): 4.03
```

### Concurrency 16

```
genai-perf --model opt350m --backend vllm --service-kind triton --streaming --url triton-server.triton-server.svc:8001 --num-prompts 100 --random-seed 1 --synthetic-input-tokens-mean 128 --synthetic-input-tokens-stddev 0 --output-tokens-mean 1
28 --concurrency 16 --measurement-interval 30000
[INFO] genai_perf.wrapper:138 - Running Perf Analyzer : 'perf_analyzer -m opt350m --async --input-data artifacts/opt350m-triton-vllm-concurrency16/llm_inputs.json --service-kind triton -u triton-server.triton-server.svc:8001 --m
easurement-interval 30000 --stability-percentage 999 --profile-export-file artifacts/opt350m-triton-vllm-concurrency16/profile_export.json -i grpc --streaming --concurrency-range 16'
                                  LLM Metrics
┏━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━┓
┃                Statistic ┃    avg ┃    min ┃    max ┃   p99 ┃    p90 ┃   p75 ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━┩
│ Time to first token (ms) │  30.27 │  21.67 │  68.83 │ 67.93 │  51.74 │ 32.17 │
│ Inter token latency (ms) │  17.46 │   9.62 │  35.27 │ 22.07 │  18.44 │ 17.92 │
│     Request latency (ms) │ 2,382… │ 105.33 │ 2,601… │ 2,58… │ 2,513… │ 2,49… │
│   Output sequence length │ 136.58 │   3.00 │ 251.00 │ 155.… │ 147.00 │ 144.… │
│    Input sequence length │ 128.02 │ 128.00 │ 129.00 │ 129.… │ 128.00 │ 128.… │
└──────────────────────────┴────────┴────────┴────────┴───────┴────────┴───────┘
Output token throughput (per sec): 904.34
Request throughput (per sec): 6.62
```

### Concurrency 32

Scaled up to 2 replicas by HPA.

```
genai-perf --model opt350m --backend vllm --service-kind triton --streaming --url triton-server.triton-server.svc:8001 --num-prompts 100 --random-seed 1 --synthetic-input-tokens-mean 128 --synthetic-input-tokens-stddev 0 --output-tokens-mean 128 --concurrency 32 --measurement-interval 30000
[INFO] genai_perf.wrapper:138 - Running Perf Analyzer : 'perf_analyzer -m opt350m --async --input-data artifacts/opt350m-triton-vllm-concurrency32/llm_inputs.json --service-kind triton -u triton-server.triton-server.svc:8001 --measurement-interval 30000 --stability-percentage 999 --profile-export-file artifacts/opt350m-triton-vllm-concurrency32/profile_export.json -i grpc --streaming --concurrency-range 32'
                                  LLM Metrics
┏━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━┓
┃                Statistic ┃    avg ┃    min ┃    max ┃   p99 ┃    p90 ┃   p75 ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━┩
│ Time to first token (ms) │  58.75 │  21.88 │ 151.93 │ 136.… │ 111.89 │ 74.75 │
│ Inter token latency (ms) │  23.31 │  16.73 │  51.55 │ 26.39 │  24.87 │ 24.18 │
│     Request latency (ms) │ 3,241… │ 115.83 │ 3,514… │ 3,51… │ 3,463… │ 3,37… │
│   Output sequence length │ 138.02 │   4.00 │ 166.00 │ 156.… │ 147.00 │ 144.… │
│    Input sequence length │ 128.02 │ 128.00 │ 129.00 │ 129.… │ 128.00 │ 128.… │
└──────────────────────────┴────────┴────────┴────────┴───────┴────────┴───────┘
Output token throughput (per sec): 1339.56
Request throughput (per sec): 9.71
```

### Concurrency 64

Scaled up to 3 replicas by HPA.

```
genai-perf --model opt350m --backend vllm --service-kind triton --streaming --url triton-server.triton-server.svc:8001 --num-prompts 100 --random-seed 1 --synthetic-input-tokens-mean 128 --synthetic-input-tokens-stddev 0 --output-tokens-mean 128 --concurrency 64 --measurement-interval 30000
[INFO] genai_perf.wrapper:138 - Running Perf Analyzer : 'perf_analyzer -m opt350m --async --input-data artifacts/opt350m-triton-vllm-concurrency64/llm_inputs.json --service-kind triton -u triton-server.triton-server.svc:8001 --measurement-interval 30000 --stability-percentage 999 --profile-export-file artifacts/opt350m-triton-vllm-concurrency64/profile_export.json -i grpc --streaming --concurrency-range 64'
                                  LLM Metrics
┏━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━┓
┃                Statistic ┃    avg ┃    min ┃    max ┃   p99 ┃    p90 ┃   p75 ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━┩
│ Time to first token (ms) │  60.04 │  21.74 │ 247.68 │ 208.… │ 151.87 │ 81.71 │
│ Inter token latency (ms) │  26.01 │  14.50 │  96.11 │ 35.48 │  33.03 │ 31.70 │
│     Request latency (ms) │ 3,568… │ 127.84 │ 4,769… │ 4,74… │ 4,580… │ 4,47… │
│   Output sequence length │ 136.72 │   2.00 │ 161.00 │ 154.… │ 147.00 │ 144.… │
│    Input sequence length │ 128.02 │ 128.00 │ 129.00 │ 129.… │ 128.00 │ 128.… │
└──────────────────────────┴────────┴────────┴────────┴───────┴────────┴───────┘
Output token throughput (per sec): 2409.03
Request throughput (per sec): 17.62
```

### Concurrency 128

Scaled up to 4 replicas by HPA.

```
genai-perf --model opt350m --backend vllm --service-kind triton --streaming --url triton-server.triton-server.svc:8001 --num-prompts 100 --random-seed 1 --synthetic-input-tokens-mean 128 --synthetic-input-tokens-stddev 0 --output-tokens-mean 128 --concurrency 128 --measurement-interval 30000
[INFO] genai_perf.wrapper:138 - Running Perf Analyzer : 'perf_analyzer -m opt350m --async --input-data artifacts/opt350m-triton-vllm-concurrency128/llm_inputs.json --service-kind triton -u triton-server.triton-server.svc:8001 --measurement-interval 30000 --stability-percentage 999 --profile-export-file artifacts/opt350m-triton-vllm-concurrency128/profile_export.json -i grpc --streaming --concurrency-range 128'
                                  LLM Metrics
┏━━━━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━┓
┃                Statistic ┃    avg ┃    min ┃    max ┃   p99 ┃    p90 ┃   p75 ┃
┡━━━━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━┩
│ Time to first token (ms) │ 119.71 │  21.76 │ 492.93 │ 444.… │ 308.79 │ 187.… │
│ Inter token latency (ms) │  39.82 │  18.59 │ 132.09 │ 57.83 │  53.68 │ 51.72 │
│     Request latency (ms) │ 5,477… │ 115.89 │ 7,706… │ 7,65… │ 7,475… │ 7,38… │
│   Output sequence length │ 136.24 │   2.00 │ 183.00 │ 155.… │ 147.00 │ 144.… │
│    Input sequence length │ 128.02 │ 128.00 │ 129.00 │ 129.… │ 128.00 │ 128.… │
└──────────────────────────┴────────┴────────┴────────┴───────┴────────┴───────┘
Output token throughput (per sec): 3076.65
Request throughput (per sec): 22.58
```
