# Keycloak de produção (Cloud Run).
# Build "otimizado": as opções de build ficam gravadas na imagem, então a subida é mais rápida
# (importante porque o serviço hiberna à noite e liga de manhã).
#   docker build -t praia-keycloak keycloak

FROM quay.io/keycloak/keycloak:26.0.7 AS builder
ENV KC_DB=postgres \
    KC_HEALTH_ENABLED=true \
    # 1 instância só (max-instances=1 no Cloud Run): cache local, sem cluster
    KC_CACHE=local
RUN /opt/keycloak/bin/kc.sh build

FROM quay.io/keycloak/keycloak:26.0.7
COPY --from=builder /opt/keycloak/ /opt/keycloak/
# Realm de produção: importado só na primeira subida (se o realm já existir, é ignorado)
COPY realm-praia.json /opt/keycloak/data/import/realm-praia.json
ENV KC_HTTP_ENABLED=true \
    KC_HTTP_PORT=8080 \
    # HTTPS termina no Google; o Keycloak confia nos headers X-Forwarded-*
    KC_PROXY_HEADERS=xforwarded
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
