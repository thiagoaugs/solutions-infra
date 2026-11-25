#!/usr/bin/env bash
# Criação ÚNICA da infraestrutura de UM ambiente no GCP (cada ambiente é um projeto GCP próprio).
# Rode no Cloud Shell (já tem gcloud, docker, node e envsubst):
#   1. ajuste gcp/ambientes/<ambiente>.env (PROJETO, ADMIN_EMAIL...)
#   2. bash gcp/setup.sh <homologacao|producao> [owner/repo-da-api] [owner/repo-do-frontend]
#      (os repositórios são opcionais: liberam o deploy pelo GitHub Actions)
#   3. bash gcp/deploy.sh <ambiente>  (backend) e, no repositório do frontend, o deploy das telas
# Faça primeiro a homologação, depois a produção. É seguro rodar de novo: só cria o que falta.
set -euo pipefail
cd "$(dirname "$0")"
source ./ambiente.sh "${1:-}"
REPO_GITHUB="${2:-}"
REPO_FRONTEND="${3:-}"
echo "Ambiente: $AMBIENTE (projeto $PROJETO)"
gcloud config set project "$PROJETO" >/dev/null
NUMERO=$(gcloud projects describe "$PROJETO" --format='value(projectNumber)')
passo() { echo; echo "==> $*"; }
existe() { "$@" >/dev/null 2>&1; }
senha() { openssl rand -hex 24; }   # só letras/números (vai dentro de SQL e variáveis)

passo "Ativando APIs"
gcloud services enable run.googleapis.com sqladmin.googleapis.com compute.googleapis.com \
  servicenetworking.googleapis.com secretmanager.googleapis.com artifactregistry.googleapis.com \
  cloudscheduler.googleapis.com iamcredentials.googleapis.com firebasehosting.googleapis.com \
  firebase.googleapis.com sts.googleapis.com fcm.googleapis.com cloudbuild.googleapis.com

passo "Rede privada (o banco não terá IP público)"
existe gcloud compute networks describe "$REDE" || gcloud compute networks create "$REDE" --subnet-mode=custom
existe gcloud compute networks subnets describe "$SUBREDE" --region "$REGIAO" || \
  gcloud compute networks subnets create "$SUBREDE" --network "$REDE" --region "$REGIAO" --range "$SUBREDE_FAIXA"
existe gcloud compute addresses describe praia-sql-range --global || \
  gcloud compute addresses create praia-sql-range --global --purpose=VPC_PEERING --prefix-length=20 --network "$REDE"
gcloud services vpc-peerings connect --service=servicenetworking.googleapis.com \
  --ranges=praia-sql-range --network "$REDE" 2>/dev/null || \
gcloud services vpc-peerings update --service=servicenetworking.googleapis.com \
  --ranges=praia-sql-range --network "$REDE" --force

passo "Segredos (senhas aleatórias no Secret Manager)"
criar_segredo() {   # nome valor
  if ! existe gcloud secrets describe "$1"; then
    printf '%s' "$2" | gcloud secrets create "$1" --replication-policy=automatic --data-file=-
  fi
}
criar_segredo db-owner-password "$(senha)"
criar_segredo db-app-password "$(senha)"
criar_segredo db-keycloak-password "$(senha)"
criar_segredo keycloak-bootstrap-password "$(senha)"
criar_segredo keycloak-api-client-secret "$(senha)"
criar_segredo praia-admin-senha-inicial "$(openssl rand -hex 8)"

# Chaves VAPID do Web Push (app web da equipe), geradas uma vez: P-256 em base64url
# (pública = ponto não comprimido de 65 bytes; privada = número d de 32 bytes).
# Trocar as chaves invalida os avisos já ativados: cada celular precisa ativar de novo.
if ! existe gcloud secrets describe webpush-chave-privada; then
  b64url() { base64 | tr -d '=\n' | tr '/+' '_-'; }
  pem="$(mktemp)"
  openssl ecparam -name prime256v1 -genkey -noout -out "$pem"
  criar_segredo webpush-chave-privada "$(openssl ec -in "$pem" -outform DER 2>/dev/null | tail -c +8 | head -c 32 | b64url)"
  criar_segredo webpush-chave-publica "$(openssl ec -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 65 | b64url)"
  rm -f "$pem"
fi
segredo() { gcloud secrets versions access latest --secret "$1"; }

if [[ "$SQL_BACKUPS" == "sim" ]]; then
  # backups diários às 7h30 de Brasília, 14 dias, e o banco não pode ser excluído por engano
  OPCOES_BANCO=(--backup-start-time=10:30 --retained-backups-count=14 --deletion-protection)
else
  OPCOES_BANCO=(--no-backup)   # homologação: dados de teste, sem custo de backup
fi
passo "Cloud SQL (PostgreSQL 16, $SQL_TIER, IP privado, backups: $SQL_BACKUPS)"
if ! existe gcloud sql instances describe "$INSTANCIA_SQL"; then
  gcloud sql instances create "$INSTANCIA_SQL" --database-version=POSTGRES_16 --edition=enterprise \
    --tier="$SQL_TIER" --region "$REGIAO" --availability-type=zonal \
    --storage-type=SSD --storage-size=10 --storage-auto-increase \
    --network="projects/$PROJETO/global/networks/$REDE" --no-assign-ip --ssl-mode=ENCRYPTED_ONLY \
    "${OPCOES_BANCO[@]}" \
    --maintenance-window-day=SUN --maintenance-window-hour=7 \
    --root-password="$(senha)"
fi
existe gcloud sql databases describe praia --instance "$INSTANCIA_SQL" || gcloud sql databases create praia --instance "$INSTANCIA_SQL"
existe gcloud sql databases describe keycloak --instance "$INSTANCIA_SQL" || gcloud sql databases create keycloak --instance "$INSTANCIA_SQL"
# praia_owner: dono do schema (Flyway). praia_app (usuário da aplicação, sujeito ao RLS) é criado pelo
# próprio Flyway na 1ª subida da API, com a senha do segredo db-app-password.
gcloud sql users list --instance "$INSTANCIA_SQL" --format='value(name)' | grep -qx praia_owner || \
  gcloud sql users create praia_owner --instance "$INSTANCIA_SQL" --password="$(segredo db-owner-password)"
gcloud sql users list --instance "$INSTANCIA_SQL" --format='value(name)' | grep -qx keycloak || \
  gcloud sql users create keycloak --instance "$INSTANCIA_SQL" --password="$(segredo db-keycloak-password)"

passo "Contas de serviço (menor privilégio)"
conta() { existe gcloud iam service-accounts describe "$1@$PROJETO.iam.gserviceaccount.com" || \
          gcloud iam service-accounts create "$1" --display-name "$2"; }
conta praia-api "API praia (Cloud Run)"
conta praia-keycloak "Keycloak (Cloud Run)"
conta praia-despertador "Despertador: hiberna/acorda o ambiente"
conta praia-deployer "Deploy pelo GitHub Actions"
SA() { echo "$1@$PROJETO.iam.gserviceaccount.com"; }

# Conta de serviço recém-criada leva alguns segundos para valer no IAM ("does not exist"), e duas mudanças de
# permissão ao mesmo tempo no projeto podem conflitar. Nesses casos, espera e tenta de novo (até ~2 minutos).
tentar() {
  local i saida
  for i in $(seq 1 12); do
    if saida=$("$@" 2>&1); then return 0; fi
    case "$saida" in
      *"does not exist"*|*"concurrent"*|*"ABORTED"*|*"409"*)
        echo "   aguardando o IAM do Google atualizar (tentativa $i de 12)..."; sleep "${ESPERA_IAM:-10}" ;;
      *) echo "$saida" >&2; return 1 ;;
    esac
  done
  echo "$saida" >&2
  return 1
}
papel_projeto() { tentar gcloud projects add-iam-policy-binding "$PROJETO" --member="serviceAccount:$(SA "$1")" --role="$2" --condition=None; }

# API e Keycloak: só leem os próprios segredos
for s in db-app-password db-owner-password keycloak-api-client-secret webpush-chave-publica webpush-chave-privada; do
  tentar gcloud secrets add-iam-policy-binding "$s" --member="serviceAccount:$(SA praia-api)" --role=roles/secretmanager.secretAccessor
done
for s in db-keycloak-password keycloak-bootstrap-password keycloak-api-client-secret praia-admin-senha-inicial; do
  tentar gcloud secrets add-iam-policy-binding "$s" --member="serviceAccount:$(SA praia-keycloak)" --role=roles/secretmanager.secretAccessor
done
# API: envia push de pedido novo para o app Android da equipe
papel_projeto praia-api roles/firebasecloudmessaging.admin
# Despertador: liga/desliga o banco e ajusta instâncias mínimas dos serviços
papel_projeto praia-despertador roles/cloudsql.editor
papel_projeto praia-despertador roles/run.developer
for alvo in praia-api praia-keycloak; do
  tentar gcloud iam service-accounts add-iam-policy-binding "$(SA "$alvo")" \
    --member="serviceAccount:$(SA praia-despertador)" --role=roles/iam.serviceAccountUser
done
# Deployer (CI): publica imagens, serviços, job, agendamento e Firebase Hosting
for p in roles/run.admin roles/artifactregistry.writer roles/cloudsql.viewer roles/cloudscheduler.admin \
         roles/firebasehosting.admin roles/serviceusage.serviceUsageConsumer; do
  papel_projeto praia-deployer "$p"
done
for alvo in praia-api praia-keycloak praia-despertador; do
  tentar gcloud iam service-accounts add-iam-policy-binding "$(SA "$alvo")" \
    --member="serviceAccount:$(SA praia-deployer)" --role=roles/iam.serviceAccountUser
done

passo "Artifact Registry (imagens)"
existe gcloud artifacts repositories describe praia --location "$REGIAO" || \
  gcloud artifacts repositories create praia --repository-format=docker --location "$REGIAO"
# Despertador: mudar a instância mínima cria uma revisão nova do serviço, e o Cloud Run exige que quem faz a mudança
# consiga ler a imagem. Só leitura, e só neste repositório de imagens.
tentar gcloud artifacts repositories add-iam-policy-binding praia --location "$REGIAO" \
  --member="serviceAccount:$(SA praia-despertador)" --role=roles/artifactregistry.reader

# Cloud Build (deploy pelo Cloud Shell monta as imagens dentro do Google): em projetos novos ele roda com a conta
# padrão do Compute, que precisa ler o código enviado, gravar a imagem no registro e escrever o log do build.
CONTA_BUILD="$NUMERO-compute@developer.gserviceaccount.com"
for p in roles/artifactregistry.writer roles/storage.objectViewer roles/logging.logWriter; do
  tentar gcloud projects add-iam-policy-binding "$PROJETO" --member="serviceAccount:$CONTA_BUILD" --role="$p" --condition=None
done

passo "Firebase Hosting (ativa o Firebase no mesmo projeto)"
curl -s -X POST -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "https://firebase.googleapis.com/v1beta1/projects/$PROJETO:addFirebase" >/dev/null \
  || echo "(não foi possível ativar automaticamente: ative em https://console.firebase.google.com escolhendo este projeto)"

if [[ -n "$REPO_GITHUB" ]]; then
  REPOS=("$REPO_GITHUB"); [[ -n "$REPO_FRONTEND" ]] && REPOS+=("$REPO_FRONTEND")
  passo "Deploy sem chave pelo GitHub Actions (Workload Identity Federation) para: ${REPOS[*]}"
  # só os repositórios informados e só a branch/tag permitida neste ambiente (main → homologação, tag v* → produção)
  CONDICAO="assertion.repository in [$(printf "'%s'," "${REPOS[@]}" | sed 's/,$//')] && $GITHUB_REF_CONDICAO"
  existe gcloud iam workload-identity-pools describe github --location=global || \
    gcloud iam workload-identity-pools create github --location=global --display-name="GitHub Actions"
  if existe gcloud iam workload-identity-pools providers describe github --location=global --workload-identity-pool=github; then
    gcloud iam workload-identity-pools providers update-oidc github --location=global --workload-identity-pool=github \
      --attribute-condition="$CONDICAO" >/dev/null
  else
    gcloud iam workload-identity-pools providers create-oidc github --location=global --workload-identity-pool=github \
      --issuer-uri="https://token.actions.githubusercontent.com" \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
      --attribute-condition="$CONDICAO"
  fi
  for repo in "${REPOS[@]}"; do
    tentar gcloud iam service-accounts add-iam-policy-binding "$(SA praia-deployer)" --role=roles/iam.workloadIdentityUser \
      --member="principalSet://iam.googleapis.com/projects/$NUMERO/locations/global/workloadIdentityPools/github/attribute.repository/$repo"
  done
  echo
  echo "Nos dois repositórios do GitHub: Settings > Environments > New environment \"$AMBIENTE\""
  echo "e, dentro dele, as variáveis (Environment variables):"
  echo "  GCP_PROJETO      = $PROJETO"
  echo "  GCP_WIF_PROVIDER = projects/$NUMERO/locations/global/workloadIdentityPools/github/providers/github"
  echo "  GCP_DEPLOYER_SA  = $(SA praia-deployer)"
fi

passo "Pronto. Próximo passo: bash gcp/deploy.sh $AMBIENTE"
echo "Senha inicial do usuário 'admin' do sistema (troca obrigatória no 1º login):"
echo "  gcloud secrets versions access latest --secret praia-admin-senha-inicial"
