FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime

ENV PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/web/simple

ADD ./python /workspace/cornserve/python

WORKDIR /workspace/cornserve/python
RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true \
    && sed -i 's|http://security.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list 2>/dev/null || true

RUN apt-get update \
      && apt-get install -y --no-install-recommends curl \
      && rm -rf /var/lib/apt/lists/* \
      && curl -LO https://github.com/mjun0812/flash-attention-prebuild-wheels/releases/download/v0.4.22/flash_attn-2.8.1+cu128torch2.9-cp311-cp311-linux_x86_64.whl \
      && pip install flash_attn-2.8.1+cu128torch2.9-cp311-cp311-linux_x86_64.whl \
      && rm flash_attn-2.8.1+cu128torch2.9-cp311-cp311-linux_x86_64.whl
RUN pip install -e '.[huggingface-te]'

ENTRYPOINT ["python", "-u", "-m", "cornserve.task_executors.huggingface.entrypoint"]
