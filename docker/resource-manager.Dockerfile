FROM ubuntu:24.04

ENV PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/web/simple

RUN sed -i 's|http://archive.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources \
    && sed -i 's|http://security.ubuntu.com/ubuntu/|http://mirrors.ustc.edu.cn/ubuntu/|g' /etc/apt/sources.list.d/ubuntu.sources

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
    && curl -LsSf https://astral.sh/uv/install.sh | sh \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV PATH="/root/.local/bin:$PATH"
RUN uv venv --python 3.11 --seed /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

ADD ./python /workspace/cornserve/python

WORKDIR /workspace/cornserve/python
RUN uv pip install -e .[resource-manager] && uv cache clean

ENTRYPOINT ["python", "-u", "-m", "cornserve.services.resource_manager.entrypoint"]
