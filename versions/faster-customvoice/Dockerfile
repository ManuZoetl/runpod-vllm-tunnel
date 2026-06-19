FROM vllm/vllm-openai:latest

USER root

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-client \
      curl \
      ca-certificates \
      git \
      ffmpeg \
      libsndfile1 && \
    rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --upgrade pip && \
    python3 -m pip install \
      "faster-qwen3-tts[demo]" \
      fastapi \
      "uvicorn[standard]" \
      soundfile \
      numpy

COPY versions/faster-customvoice/faster_customvoice_server.py /opt/jarvis/faster_customvoice_server.py
COPY versions/faster-customvoice/start-faster-customvoice.sh /usr/local/bin/start-faster-customvoice.sh

RUN chmod +x /usr/local/bin/start-faster-customvoice.sh

ENTRYPOINT ["/usr/local/bin/start-faster-customvoice.sh"]
CMD []
