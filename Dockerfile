FROM hashicorp/vault:2.0.3 AS vault

FROM amazon/aws-cli:2.34.48

USER root
RUN dnf install -y jq \
    && dnf clean all

COPY --from=vault /bin/vault /usr/local/bin/vault
COPY app/entrypoint.sh /usr/local/bin/gateway-demo

RUN chmod 0755 /usr/local/bin/vault /usr/local/bin/gateway-demo

USER 10001:10001
ENTRYPOINT ["/usr/local/bin/gateway-demo"]
