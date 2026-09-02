FROM hashicorp/vault:2.0.3 AS vault
FROM node:20.20.0-bookworm-slim AS serverless

RUN npm install --global serverless@3.40.0

FROM amazon/aws-cli:2.34.48

USER root
RUN dnf install -y jq \
    && dnf clean all

COPY --from=vault /bin/vault /usr/local/bin/vault
COPY --from=serverless /usr/local/bin/node /usr/local/bin/node
COPY --from=serverless /usr/local/lib/node_modules/serverless /usr/local/lib/node_modules/serverless
COPY app/entrypoint.sh /usr/local/bin/gateway-demo
COPY --chown=10001:10001 processor /opt/image-processor

RUN mkdir -p /home/demo \
    && chown 10001:10001 /home/demo \
    && ln -s /usr/local/lib/node_modules/serverless/bin/serverless.js /usr/local/bin/serverless \
    && chmod 0755 /usr/local/bin/vault /usr/local/bin/gateway-demo

ENV HOME=/home/demo
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/gateway-demo"]
