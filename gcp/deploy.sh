#!/usr/bin/env bash
# Deploy do backend: imagens → despertador + agendamento → Keycloak → API.
# As telas (Angular, Firebase Hosting) são publicadas pelo repositório solutions-praia-frontend.
# Uso: bash gcp/deploy.sh <homologacao|producao>
#   API_DIR = pasta do código da API (repositório solutions-praia-api), de onde sai a imagem da API.
#             Padrão: a pasta irmã ../solutions-praia-api (os dois repositórios lado a lado).
# O GitHub Actions do repositório da API chama este script: homologação a cada push na main, produção a cada tag v*.
# Se o ambiente estiver hibernado, ele é acordado por 1h antes do deploy (os serviços precisam do banco para subir).
set -euo pipefail
INFRA="$(cd "$(dirname "$0")/.." && pwd)"
source "$INFRA/gcp/ambiente.sh" "${1:-}"
API_DIR="$(cd "${API_DIR:-$INFRA/../solutions-praia-api}" 2>/dev/null && pwd)" || {
  echo "Código da API não encontrado. Informe API_DIR=<pasta do solutions-praia-api>" >&2; exit 1; }
[[ -f "$API_DIR/Dockerfile" ]] || { echo "Sem Dockerfile em $API_DIR (é a pasta do solutions-praia-api?)" >&2; exit 1; }
echo "Ambiente: $AMBIENTE (projeto $PROJETO) | API: $API_DIR"

# Nome (tag) de cada imagem = versão do código de onde ela sai, para um deploy repetido reaproveitar só o que não mudou:
#   - API: commit (homologação) ou versão (produção, TAG=v1.2.3) do solutions-praia-api;
#   - Keycloak e despertador: saem DESTE repositório, então levam também o commit do solutions-infra.
# Pasta com alterações ainda sem commit ganha um carimbo de hora (nunca reaproveita uma imagem antiga por engano).
versao() {   # pasta
  local v; v="$(git -C "$1" rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
  [[ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]] && v="$v-mod$(date +%Y%m%d%H%M%S)"
  echo "$v"
}
TAG="${TAG:-$(versao "$API_DIR")}"
TAG_INFRA="$(versao "$INFRA")"
REGISTRO="$REGIAO-docker.pkg.dev/$PROJETO/praia"
NUMERO=$(gcloud projects describe "$PROJETO" --format='value(projectNumber)')
export PROJETO REGIAO REDE SUBREDE ADMIN_EMAIL AMBIENTE MAX_API DADOS_EXEMPLO
export IMAGEM_API="$REGISTRO/praia-api:$TAG"
export IMAGEM_KEYCLOAK="$REGISTRO/praia-keycloak:$TAG-$TAG_INFRA"
IMAGEM_DESPERTADOR="$REGISTRO/praia-despertador:$TAG-$TAG_INFRA"
export URL_PUBLICA="${DOMINIO:+https://$DOMINIO}"; URL_PUBLICA="${URL_PUBLICA:-https://$PROJETO.web.app}"
# URL determinística do Cloud Run: https://<serviço>-<número do projeto>.<região>.run.app
export URL_KEYCLOAK="https://praia-keycloak-$NUMERO.$REGIAO.run.app"
export IP_SQL=$(gcloud sql instances describe "$INSTANCIA_SQL" --project "$PROJETO" --format='value(ipAddresses[0].ipAddress)')
passo() { echo; echo "==> $*"; }

# Como as imagens são construídas:
#   - cloudbuild (padrão fora do GitHub Actions, ex.: Cloud Shell): só o código sobe; a imagem é montada e guardada
#     dentro da rede do Google. O Cloud Shell limita conexões e o envio de imagens grandes com docker falha
#     ("connection refused" no Artifact Registry).
#   - docker (padrão no GitHub Actions, onde a rede não tem esse limite): build e push locais.
#   Para escolher à mão: CONSTRUIR_COM=cloudbuild|docker
MODO_BUILD="${CONSTRUIR_COM:-$([[ -n "${CI:-}" ]] && echo docker || echo cloudbuild)}"
passo "Imagens ($TAG, via $MODO_BUILD)"
[[ "$MODO_BUILD" == docker ]] && gcloud auth configure-docker "$REGIAO-docker.pkg.dev" --quiet

# Envio com nova tentativa: falha momentânea de rede não derruba o deploy (o docker retoma de onde parou).
enviar_imagem() {
  local i
  for i in 1 2 3 4; do
    docker push -q "$1" && return 0
    [[ $i -lt 4 ]] && { echo "   falha ao enviar $1 (tentativa $i de 4); tentando de novo em ${ESPERA_PUSH:-15}s..."; sleep "${ESPERA_PUSH:-15}"; }
  done
  echo "Não foi possível enviar $1. Teste a rede: curl -sI https://$REGIAO-docker.pkg.dev/v2/ (esperado: 401)" >&2
  return 1
}

construir() {   # imagem pasta (com Dockerfile)
  # a mesma versão já está no registro (ex.: deploy repetido depois de uma falha): não constrói de novo
  if gcloud artifacts docker images describe "$1" --project "$PROJETO" >/dev/null 2>&1; then
    echo "   $1 já existe no registro, reaproveitando"
    return 0
  fi
  if [[ "$MODO_BUILD" == docker ]]; then
    docker build -t "$1" "$2" && enviar_imagem "$1"
  else
    gcloud builds submit "$2" --tag "$1" --project "$PROJETO" --quiet
  fi
}
construir "$IMAGEM_API" "$API_DIR"
construir "$IMAGEM_KEYCLOAK" "$INFRA/keycloak"
construir "$IMAGEM_DESPERTADOR" "$INFRA/gcp/despertador"

passo "Despertador (Cloud Run Job) e agendamento a cada 15 min"
gcloud run jobs deploy praia-despertador --project "$PROJETO" --region "$REGIAO" --image "$IMAGEM_DESPERTADOR" \
  --service-account "praia-despertador@$PROJETO.iam.gserviceaccount.com" \
  --task-timeout=15m --max-retries=0 --cpu=1 --memory=512Mi \
  --set-env-vars="^@^PROJETO=$PROJETO@REGIAO=$REGIAO@INSTANCIA_SQL=$INSTANCIA_SQL@SERVICOS=$SERVICOS_SEMPRE_PRONTOS@MIN_INSTANCIAS=$MIN_INSTANCIAS@HORA_ACORDAR=$HORA_ACORDAR@HORA_HIBERNAR=$HORA_HIBERNAR@DIAS=$DIAS@FUSO=$FUSO" \
  --quiet
URI_JOB="https://run.googleapis.com/v2/projects/$PROJETO/locations/$REGIAO/jobs/praia-despertador:run"
AGENDA=(--location "$REGIAO" --schedule="*/15 * * * *" --time-zone="$FUSO" --uri="$URI_JOB" --http-method=POST
        --oauth-service-account-email="praia-despertador@$PROJETO.iam.gserviceaccount.com" --project "$PROJETO")
gcloud scheduler jobs update http praia-despertador "${AGENDA[@]}" --quiet 2>/dev/null || \
  gcloud scheduler jobs create http praia-despertador "${AGENDA[@]}" --quiet

if [[ "$(gcloud sql instances describe "$INSTANCIA_SQL" --project "$PROJETO" --format='value(settings.activationPolicy)')" != "ALWAYS" ]]; then
  passo "Ambiente hibernado: acordando por 1h para o deploy"
  gcloud run jobs execute praia-despertador --project "$PROJETO" --region "$REGIAO" --args=acordar,1 --wait
fi

# Preserva a instância mínima atual (definida pelo despertador); serviço novo começa com 1
min_atual() {
  gcloud run services describe "$1" --project "$PROJETO" --region "$REGIAO" --format=json 2>/dev/null \
    | grep -o '"autoscaling.knative.dev/minScale": *"[0-9]*"' | grep -o '[0-9]*"$' | tr -d '"' || true
}
export MIN_KEYCLOAK=$(min_atual praia-keycloak); MIN_KEYCLOAK="${MIN_KEYCLOAK:-1}"
export MIN_API=$(min_atual praia-api); MIN_API="${MIN_API:-1}"
VARS='${AMBIENTE} ${MAX_API} ${DADOS_EXEMPLO} ${PROJETO} ${REGIAO} ${REDE} ${SUBREDE} ${IP_SQL} ${URL_PUBLICA} ${URL_KEYCLOAK} ${ADMIN_EMAIL} ${IMAGEM_API} ${IMAGEM_KEYCLOAK} ${MIN_API} ${MIN_KEYCLOAK}'

implantar() {   # serviço arquivo
  envsubst "$VARS" < "$INFRA/gcp/servicos/$2" > "/tmp/$2"
  gcloud run services replace "/tmp/$2" --project "$PROJETO" --region "$REGIAO" --quiet
  # público: o cliente da praia não faz login (a segurança das rotas da equipe é o token do Keycloak)
  gcloud run services add-iam-policy-binding "$1" --project "$PROJETO" --region "$REGIAO" \
    --member=allUsers --role=roles/run.invoker --quiet >/dev/null
}
passo "Keycloak ($URL_KEYCLOAK)"
implantar praia-keycloak keycloak.yaml
passo "API"
implantar praia-api api.yaml

passo "Deploy concluído"
echo "API:      $(gcloud run services describe praia-api --project "$PROJETO" --region "$REGIAO" --format='value(status.url)')"
echo "Keycloak: $URL_KEYCLOAK"
echo "As telas (Angular) são publicadas pelo repositório solutions-praia-frontend em $URL_PUBLICA"
