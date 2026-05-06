# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build, Lint, and Test

```bash
# Install dev dependencies (GPU version)
pip install -e "python/[dev]"
# Or without GPU dependencies:
pip install -e "python/[dev-no-gpu]"

# Generate protobuf Python bindings (required before most work)
bash scripts/generate_pb.sh

# Lint and type-check
bash scripts/lint.sh
# Or individually:
ruff check python/ tasklib/ --target-version py311
pyright python/ tasklib/

# Run all tests
python -m pytest python/tests/

# Run a specific test file
python -m pytest python/tests/task/test_base.py

# Build Docker images (set REGISTRY env var: local, none, minikube, or URL)
export REGISTRY=local && bash scripts/build_export_images.sh

# Preview documentation
bash scripts/preview_docs.sh
```

## Architecture: Cornserve Distributed Multimodal Serving

Cornserve is a distributed inference platform for any-to-any multimodal AI models. It splits complex models into smaller, independently scalable components (**model fission**) and shares common components across apps. It runs on Kubernetes.

### Service Mesh (microservices)

All services run as Kubernetes pods and communicate via **gRPC** (for control-plane) and **HTTP** (for data-plane / user-facing). Proto definitions are in `proto/v1/`. Generated Python bindings go to `python/cornserve/services/pb/`.

- **Gateway** (`python/cornserve/services/gateway/`) — The user-facing HTTP/WebSocket API server (FastAPI). Handles app registration, invocation, tasklib deployment, and profiling. Manages the `AppManager` (app lifecycle via `app/manager.py`) and `TaskManager` (task lifecycle via `gateway/task_manager.py`). The router is in `gateway/router.py`.

- **Task Manager** (`python/cornserve/services/task_manager/`) — Per-unit-task manager. Handles scaling (add/remove GPUs), routing (consistent hashing), health checking, and load reconciliation. Deployed as a sidecar alongside task executor pods. Communicates via gRPC with the Resource Manager and Task Dispatcher. Core logic is in `task_manager/manager.py`.

- **Task Dispatcher** (`python/cornserve/services/task_dispatcher/`) — Routes individual task graph invocations to the correct Task Executor replicas. Uses consistent hashing for cache-aware routing. Exposes both HTTP (data-plane) and gRPC (control-plane) endpoints.

- **Resource Manager** (`python/cornserve/services/resource_manager/`) — Manages cluster GPU resources and Sidecar lifecycle. Decides which GPUs to allocate to which task managers. Watches Kubernetes CRs.

- **Sidecar** (`python/cornserve/services/sidecar/`, `python/cornserve/sidecar/`) — GPU-sidecar process enabling cross-model communication via shared memory and UCX. Manages shm buffers (`shm_manager.py`), sends/receives tensors between models, and schedules compute on local GPUs.

- **Task Executors** (`python/cornserve/task_executors/`) — Model-specific serving containers:
  - `eric/` — Vision/multimodal encoder (transformers-based)
  - `geri/` — Image/video generation (diffusion models)
  - `huggingface/` — Generic HuggingFace Transformers inference
  - `vllm/` (in `third_party/vllm/`) — LLM inference engine
  - Each executor has a FastAPI server (`api.py`), engine logic, and an `entrypoint.py`.

### Task Framework (core abstraction)

Located in `python/cornserve/task/base.py`. This is the heart of the programming model:

- **`Task`** — Base class for all tasks. Composite tasks can contain sub-tasks as instance attributes. The `invoke()` method defines task logic. The `__call__` method uses a **record/replay** pattern: runs `invoke()` once to record sub-task invocations (with placeholder outputs from `make_record_output()`), dispatches them to the Task Dispatcher, then re-runs `invoke()` with real outputs.

- **`UnitTask`** — A task that doesn't invoke other tasks. The **unit of deployment and scaling**. Associated with a `TaskExecutionDescriptor` that determines which executor runs it. Equivalent unit tasks (same `root_unit_task_cls`, same descriptor, same field values) share a Task Manager and are deployed together.

- **`Stream`** — Generic streaming output. Supports `.transform()` for type-safe stream transformations.

- **`TaskContext`** — Per-invocation context. Manages recording/replaying invocations. Uses `ContextVar` for propagation through the call stack.

- **`TaskExecutionDescriptor`** (`python/cornserve/task_executors/descriptor/base.py`) — Describes HOW a unit task should execute: which container image, entrypoint, and GPU resources are needed.

### App Framework

Located in `python/cornserve/app/base.py` and `python/cornserve/services/gateway/app/manager.py`. Users write Python source files containing:

1. A `Config` class extending `AppConfig` with a `tasks` dict mapping names to `Task` instances
2. A Pydantic request model
3. A Pydantic response model
4. An async `serve(request) -> Response | AsyncIterator[Response]` function

The Gateway dynamically loads this source, discovers all `UnitTask` instances, deploys them, and routes invocation requests through the task graph.

### CLI (`python/cornserve/cli/`)

Built with `tyro`. Commands: `register`, `unregister`, `list`, `invoke`, `tasklib deploy/purge`, `deploy_profiles`. Uses the `CORNSERVE_GATEWAY_URL` env var (default: `http://localhost:30080`).

### Key Patterns

- **Record/Replay**: In `TaskContext`, `invoke()` runs twice — first to record (fake outputs), second to replay (real outputs after dispatch). This enables automatic task graph construction.
- **CRD-driven**: Task definitions, execution descriptors, and unit task instances are stored as Kubernetes Custom Resources. Control-plane services watch these CRs.
- **Lazy-loaded constants**: Container image names in `constants.py` use module-level `__getattr__` for lazy evaluation from env vars.
- **gRPC service stubs** are in `python/cornserve/services/pb/` (generated by `scripts/generate_pb.sh`). Import paths must use relative imports like `from . import common_pb2` (the generation script fixes this via `sed`).
- **`tasklib/`** is a separate Python package (`cornserve-tasklib`) containing built-in task definitions shared across the cluster.

### Kubernetes Deployment

Kustomize overlays in `kubernetes/kustomize/cornserve/` and `kubernetes/kustomize/cornserve-system/`. Docker images defined in `docker/*.Dockerfile`. The `scripts/build_export_images.sh` script handles building, with `REGISTRY=local` building directly into k3s containerd.
