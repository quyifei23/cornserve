FROM pytorch/pytorch:2.9.0-cuda12.8-cudnn9-runtime

ENV PIP_INDEX_URL=https://mirrors.ustc.edu.cn/pypi/web/simple

ADD ./python /workspace/cornserve/python

WORKDIR /workspace/cornserve/python
RUN pip install -e '.[geri]'

ENTRYPOINT ["python", "-u", "-m", "cornserve.task_executors.geri.entrypoint"]
