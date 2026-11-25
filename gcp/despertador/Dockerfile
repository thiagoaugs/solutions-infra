# Imagem do Cloud Run Job "praia-despertador" (gcloud + script).
FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:slim
# tzdata: o horário de liga/desliga é calculado no fuso de São Paulo
RUN apt-get update && apt-get install -y --no-install-recommends tzdata && rm -rf /var/lib/apt/lists/*
COPY despertador.sh /usr/local/bin/despertador.sh
RUN chmod +x /usr/local/bin/despertador.sh
ENTRYPOINT ["/usr/local/bin/despertador.sh"]
CMD ["verificar"]
