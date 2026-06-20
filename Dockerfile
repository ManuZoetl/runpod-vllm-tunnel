FROM vllm/vllm-openai:latest

USER root

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      openssh-client \
      openssh-server \
      curl \
      ca-certificates && \
    mkdir -p /run/sshd /root/.ssh && \
    chmod 700 /root/.ssh && \
    rm -rf /var/lib/apt/lists/*

COPY start-with-tunnel.sh /usr/local/bin/start-with-tunnel.sh
RUN chmod +x /usr/local/bin/start-with-tunnel.sh

ENTRYPOINT ["/usr/local/bin/start-with-tunnel.sh"]
CMD []