#!/usr/bin/env bash
# Atalho para acordar/hibernar um ambiente no GCP (Cloud Shell / Linux / macOS / Git Bash).
#   gcp/despertador-cli.sh homologacao acordar [HORAS]   ← liga para testar; hiberna sozinho depois
#   gcp/despertador-cli.sh homologacao hibernar
#   gcp/despertador-cli.sh producao status
set -euo pipefail
source "$(dirname "$0")/ambiente.sh" "${1:-}"

ACAO="${2:-status}"
ARGS="$ACAO"
if [[ "$ACAO" == "acordar" ]]; then ARGS="acordar,${3:-$HORAS_EXTRAS_PADRAO}"; fi

echo "[$AMBIENTE] executando despertador: $ARGS (pode levar alguns minutos ao ligar o banco)..."
gcloud run jobs execute praia-despertador --project "$PROJETO" --region "$REGIAO" --args="$ARGS" --wait
