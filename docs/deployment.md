# Cornserve 部署指南

本文档记录在一台 8×A100-40GB 单机（Ubuntu 22.04）上从零部署 Cornserve 的完整流程。

## 架构概览

```
┌─────────────────────────────────────────────────────────┐
│ k3s (单节点 control-plane)                               │
│                                                         │
│  cornserve-system 命名空间                                │
│  ┌──────────────────────────────────────────┐           │
│  │ jaeger (链路追踪)                          │           │
│  └──────────────────────────────────────────┘           │
│                                                         │
│  cornserve 命名空间                                       │
│  ┌──────────┐ ┌──────────────────┐ ┌─────────────────┐  │
│  │ gateway  │ │ resource-manager │ │ task-dispatcher  │  │
│  │ (FastAPI)│ │ (GPU 分配)       │ │ (请求路由 ×3)   │  │
│  │ :30080   │ │                  │ │                 │  │
│  └──────────┘ └──────────────────┘ └─────────────────┘  │
│                                                         │
│  ┌──────┐ ┌──────┐ ┌──────┐       ┌──────┐            │
│  │sidecar│ │sidecar│ │sidecar│ ... │sidecar│  ← 8 个    │
│  │  0   │ │  1   │ │  2   │       │  7   │            │
│  └──────┘ └──────┘ └──────┘       └──────┘            │
│    GPU0    GPU1    GPU2             GPU7               │
│                                                         │
│  动态 Pod (task executor，按需创建):                      │
│  ┌─────────────┐ ┌──────────────┐ ┌──────────────────┐ │
│  │ vllm-...    │ │ geri-audio-..│ │ vllm-...-talker  │ │
│  │ (LLM TP2)   │ │ (Audio Gen)  │ │ (Talker)         │ │
│  │ Ranks 1-2   │ │ Rank 3       │ │ Rank 0           │ │
│  └─────────────┘ └──────────────┘ └──────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

## 第一步：安装 k3s

### 1.1 准备 k3s 配置文件

```bash
sudo mkdir -p /etc/rancher/k3s
```

`/etc/rancher/k3s/config.yaml`:
```yaml
write-kubeconfig-mode: "0644"
default-runtime: "nvidia"
```

`/etc/rancher/k3s/registries.yaml`:
```yaml
mirrors:
  "localhost:5000":
    endpoint:
      - "http://localhost:5000"
```

### 1.2 安装 NVIDIA Container Toolkit

```bash
# 添加 NVIDIA 仓库
distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
curl -s -L https://nvidia.github.io/libnvidia-container/gpgkey | sudo apt-key add -
curl -s -L https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt-get update
sudo apt-get install -y nvidia-container-toolkit
```

### 1.3 配置 containerd 使用 nvidia runtime

k3s 安装后会自动生成 containerd 配置。配置 nvidia runtime：

```bash
# 编辑 /var/lib/rancher/k3s/agent/etc/containerd/config.toml
# 在 [plugins."io.containerd.grpc.v1.cri".containerd.runtimes] 下添加：
#   [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia]
#     runtime_type = "io.containerd.runc.v2"
#     [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.nvidia.options]
#       BinaryName = "/usr/bin/nvidia-container-runtime"
```

### 1.4 安装 k3s

```bash
curl -sfL https://get.k3s.io | sh -
```

### 1.5 配置 kubectl

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

### 1.6 安装 NVIDIA Device Plugin

```bash
kubectl create -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.1/deployments/static/nvidia-device-plugin.yml
```

### 1.7 验证

```bash
kubectl get nodes
# 应显示 Ready
nvidia-smi
# 应显示所有 GPU
```

---

## 第二步：构建 Docker 镜像

### 2.1 关键概念：两种 containerd

宿主机上有两个独立的 containerd 实例：

| | 系统 containerd | k3s containerd |
|---|---|---|
| **Socket** | `/run/containerd/containerd.sock` | `/run/k3s/containerd/containerd.sock` |
| **工具** | `nerdctl` (默认) | `k3s ctr` 或 `nerdctl --address /run/k3s/containerd/containerd.sock` |
| **用途** | 系统级容器 | k3s 集群的 Pod 镜像 |

**nerdctl 默认连接系统 containerd**，而 k3s 使用自己的 containerd。两者互不相通。

### 2.2 构建镜像到 k3s 的 containerd

构建脚本使用 `nerdctl --namespace k8s.io build`，镜像进入系统 containerd，**k3s 看不到**。

正确的做法是在构建前设置环境变量：

```bash
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
```

再运行构建脚本，镜像就会直接进入 k3s 的 containerd：

```bash
export REGISTRY=local
export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock
bash scripts/build_export_images.sh geri vllm
```

### 2.3 验证镜像

```bash
# 方式 1：k3s 自带工具
sudo k3s ctr images ls | grep cornserve

# 方式 2：nerdctl 指向 k3s socket
sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io images ls | grep cornserve
```

两者输出应一致，格式如：
```
docker.io/cornserve/vllm:latest    sha256:...    18.3 GiB
docker.io/cornserve/geri:latest    sha256:...    4.3 GiB
```

### 2.4 如果镜像进了系统 containerd（救急方案）

如果你忘记设置 `CONTAINERD_ADDRESS`，镜像会被错误地建到系统 containerd：

```bash
# 从系统 containerd 导出，导入到 k3s
sudo nerdctl --namespace k8s.io save cornserve/geri:latest | \
  sudo k3s ctr images import -
```

### 2.5 镜像命名规则

`REGISTRY=local` 时，构建的镜像名为 `cornserve/<服务>:latest`。
kustomize overlay (`kubernetes/kustomize/cornserve/overlays/local/`) 会把它重写为 `docker.io/cornserve/<服务>:latest`。
因此 `k3s ctr images ls` 显示的前缀是 `docker.io/cornserve/`。

---

## 第三步：部署 Cornserve 服务

### 3.1 生成 protobuf 代码

```bash
bash scripts/generate_pb.sh
```

### 3.2 安装 Python 依赖

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -e 'python/[dev]'
```

### 3.3 部署到 k3s

```bash
kubectl apply -k kubernetes/kustomize/cornserve/overlays/local/
```

这会创建：
- **命名空间**: `cornserve`、`cornserve-system`
- **CRD**: `executiondescriptors`、`taskdefinitions`、`unittaskinstances`、`unittaskprofiles`、`latesttasklibrvs`
- **服务**: gateway (ClusterIP + NodePort:30080)、resource-manager、task-dispatcher、sidecar (headless)
- **Deployment**: gateway、resource-manager、task-dispatcher (3 replicas)
- **Sidecar Pods**: 由 Resource Manager 动态创建（每个 GPU 一个）

### 3.4 验证部署

```bash
# 检查所有 Pod 运行
kubectl get pods -n cornserve

# 检查服务
kubectl get svc -n cornserve

# 测试 gateway
curl http://localhost:30080/health
```

预期输出：所有 Pod `Running`，Gateway 健康检查返回 `200 OK`。

---

## 第四步：部署 Tasklib

Tasklib 包含内置的 Task 定义和 Execution Descriptor。

```bash
source .venv/bin/activate
cornserve tasklib deploy
```

这会创建：
- UnitTask 和 Descriptor CR（vllm、geri、eric、huggingface 等）
- Composite Task CR（MLLMTask、OmniTask 等）

验证：
```bash
kubectl get taskdefinitions -n cornserve
kubectl get executiondescriptors -n cornserve
```

---

## 第五步：配置 GPU Profile（重要）

### 5.1 为什么需要 Profile

每个 UnitTask 默认分配 **1 张 GPU**（`profile.py:273`），超大型模型会 OOM。
Profile 定义了某个 Task 需要多少 GPU。

例如 `Qwen3-Omni-30B-A3B-Instruct` 约 65GB 权重，单张 40GB A100 装不下，需要 2 张做张量并行。

### 5.2 Profile 文件格式

`profiles/llmunittask-qwen3-omni-thinker.json`:
```json
{
  "task": {
    "__class__": "LLMUnitTask",
    "model_id": "/data/models/Qwen3-Omni-30B-A3B-Instruct",
    "receive_embeddings": false,
    "execution_descriptor_name": null
  },
  "num_gpus_to_profile": {
    "2": {"launch_args": []}
  }
}
```

**关键**：`model_id` 必须与 App 代码中 Task 的 `model_id` 完全一致，否则 `is_equivalent_to()` 匹配失败，回退到默认 1 GPU。

### 5.3 部署 Profile

```bash
source .venv/bin/activate
cornserve deploy-profiles profiles/
```

验证：
```bash
kubectl get unittaskprofiles -n cornserve -o yaml
```

---

## 第六步：注册 App

### 6.1 示例 App

```bash
source .venv/bin/activate
cornserve register examples/qwen3_omni.py
```

这会把 App 的 Task 图注册到 Gateway，Resource Manager 会创建对应的 Task Executor Pod。

### 6.2 观察日志

注册过程会 stream executor 日志到终端。关注：
- vllm executor: 模型加载、张量并行、health check
- geri executor: 模型配置加载

### 6.3 验证

```bash
cornserve list
# 应显示 app-<id>  qwen3_omni  Ready
```

---

## 第七步：推理

```bash
# 纯文本响应
cornserve invoke qwen3_omni --aggregate-keys choices.0.delta.content --data - <<EOF
model: "/data/models/Qwen3-Omni-30B-A3B-Instruct"
messages:
- role: "user"
  content:
  - type: text
    text: "Write a short poem about AI."
return_audio: false
EOF

# 带音频响应
cornserve invoke qwen3_omni --audio-key choices.0.delta.audio.data --data - <<EOF
model: "/data/models/Qwen3-Omni-30B-A3B-Instruct"
messages:
- role: "user"
  content:
  - type: text
    text: "Tell me a short story."
return_audio: true
EOF
```

---

## 故障排查

### GPU OOM（30B 模型装不进单张 A100）

**症状**：`torch.OutOfMemoryError: CUDA out of memory`

**原因**：默认 Profile 只分配 1 GPU，30B MoE 模型 ~65GB > 40GB。

**解决**：检查 `cornserve deploy-profiles` 是否部署了对应的 Profile，且 model_id 匹配。

### HFValidationError（本地路径被拒绝）

**症状**：`Repo id must be in the form 'repo_name' or 'namespace/repo_name'`

**原因**：Docker 镜像内的 `transformers`/`huggingface_hub` 版本拒绝以 `/` 开头的本地路径。

**解决**：源码已修复（`loader.py` 的 `is_local` 回退，`config.py:528` 的本地路径检查），重新构建 Docker 镜像即可。

### 构建脚本将镜像放到错误的 containerd

**症状**：`k3s ctr images ls` 能看到镜像但 `nerdctl --namespace k8s.io images ls` 看不到（或反过来）。

**原因**：nerdctl 连接系统 containerd，k3s 用独立 containerd。

**解决**：构建前设置 `export CONTAINERD_ADDRESS=/run/k3s/containerd/containerd.sock`。

### App 注册失败

**症状**：`App registration failed. Failed to deploy tasks`

**排查步骤**：
1. 检查 executor Pod 日志：`kubectl logs -n cornserve <pod-name>`
2. 确认模型文件存在于 `/data/models/`
3. 确认 Profile 已部署且 model_id 匹配
4. 确认 Docker 镜像是最新构建的

### 常用调试命令

```bash
# 查看所有 CRD 资源
kubectl get executiondescriptors,taskdefinitions,unittaskinstances,unittaskprofiles -n cornserve

# 查看 executor Pod 日志
kubectl logs -n cornserve te-<executor-name> --tail=100

# 删除所有 executor Pod（Resource Manager 会重建）
kubectl delete pod -n cornserve -l app=task-executor

# 重新部署 tasklib
cornserve tasklib deploy
```
