# Build flash-attn wheel inside the `devel` image which has `nvcc`.
FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-devel AS builder

ARG max_jobs=16
ENV MAX_JOBS=${max_jobs}
ENV NVCC_THREADS=8
RUN pip wheel -w /tmp/wheels --no-build-isolation --no-deps --verbose flash-attn==2.7.4.post1

# Actual Eric runs inside the `runtime` image. Just copy over the flash-attn wheel.
FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime AS eric

ENV PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/web/simple

COPY --from=builder /tmp/wheels/*.whl /tmp/wheels/
RUN pip install --no-cache-dir /tmp/wheels/*.whl && rm -rf /tmp/wheels

RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true \
    && sed -i 's|http://security.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    build-essential \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

ADD ./python /workspace/cornserve/python

WORKDIR /workspace/cornserve/python
RUN pip install -e '.[eric]'

ENTRYPOINT ["python", "-u", "-m", "cornserve.task_executors.eric.entrypoint"]

# Eric that has audio support.
FROM eric AS eric-audio

RUN pip install -e '.[audio]'
