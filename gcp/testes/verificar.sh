#!/usr/bin/env bash
# Verificação dos scripts de infra SEM acessar o GCP (roda no GitHub Actions e no seu computador):
#   bash gcp/testes/verificar.sh
# 1. sintaxe de todos os scripts;  2. valores obrigatórios em cada ambiente;  3. proteção de ambiente;
# 4. arquivos do Cloud Run gerados para cada ambiente;  5. fluxos do despertador com um gcloud simulado.
set -uo pipefail
RAIZ="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FALHAS=0
ok()    { echo "  ok    $*"; }
falha() { echo "  FALHA $*"; FALHAS=$((FALHAS + 1)); }

echo "== 1. sintaxe dos scripts"
while IFS= read -r f; do
  if bash -n "$f" 2>"$TMP/erro"; then ok "${f#"$RAIZ"/}"; else falha "${f#"$RAIZ"/}: $(cat "$TMP/erro")"; fi
done < <(find "$RAIZ/gcp" -name '*.sh' | sort)

echo "== 2. valores obrigatórios em cada ambiente"
OBRIGATORIOS=(AMBIENTE PROJETO REGIAO INSTANCIA_SQL SQL_TIER SQL_BACKUPS MAX_API DADOS_EXEMPLO REDE SUBREDE SUBREDE_FAIXA
              GITHUB_REF_CONDICAO HORA_ACORDAR HORA_HIBERNAR DIAS FUSO SERVICOS_SEMPRE_PRONTOS MIN_INSTANCIAS HORAS_EXTRAS_PADRAO)
for env in "$RAIZ"/gcp/ambientes/*.env; do
  nome="$(basename "$env" .env)"
  faltando=$( (set +u; # shellcheck source=/dev/null
               source "$env"; for v in "${OBRIGATORIOS[@]}"; do [[ -n "${!v:-}" ]] || printf '%s ' "$v"; done) )
  if [[ -z "$faltando" ]]; then ok "$nome"; else falha "$nome: faltam $faltando"; fi
  # shellcheck source=/dev/null
  [[ "$(source "$env"; echo "$AMBIENTE")" == "$nome" ]] || falha "$nome: AMBIENTE dentro do arquivo não bate com o nome"
done

echo "== 3. proteção de ambiente (sem ambiente ou com nome errado, nada roda)"
for arg in "" "staging"; do
  if (bash "$RAIZ/gcp/ambiente.sh" "$arg") >/dev/null 2>&1; then falha "ambiente.sh aceitou '$arg'"; else ok "ambiente.sh recusa '${arg:-(vazio)}'"; fi
done

echo "== 4. arquivos do Cloud Run gerados para cada ambiente"
VARS='${AMBIENTE} ${MAX_API} ${DADOS_EXEMPLO} ${PROJETO} ${REGIAO} ${REDE} ${SUBREDE} ${IP_SQL} ${URL_PUBLICA} ${URL_KEYCLOAK} ${ADMIN_EMAIL} ${IMAGEM_API} ${IMAGEM_KEYCLOAK} ${MIN_API} ${MIN_KEYCLOAK}'
if ! command -v envsubst >/dev/null; then
  echo "  (sem envsubst nesta máquina: etapa pulada)"
else
  TEM_YAML=0; python3 -c 'import yaml' 2>/dev/null && TEM_YAML=1
  for env in "$RAIZ"/gcp/ambientes/*.env; do
    nome="$(basename "$env" .env)"
    for servico in "$RAIZ"/gcp/servicos/*.yaml; do
      saida="$TMP/$nome-$(basename "$servico")"
      ( set -a; set +u
        # shellcheck source=/dev/null
        source "$env"
        export IP_SQL=10.0.0.3 URL_PUBLICA=https://exemplo.web.app URL_KEYCLOAK=https://kc.exemplo
        export IMAGEM_API=img:1 IMAGEM_KEYCLOAK=img:1 MIN_API=1 MIN_KEYCLOAK=1
        envsubst "$VARS" < "$servico" > "$saida" )
      sobrou=$(grep -v '^[[:space:]]*#' "$saida" | grep -o '\${[A-Z_]*}' | sort -u | tr '\n' ' ')
      if [[ -n "$sobrou" ]]; then falha "$nome/$(basename "$servico"): sem valor para $sobrou"; continue; fi
      if [[ $TEM_YAML == 1 ]] && ! python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$saida" 2>"$TMP/erro"; then
        falha "$nome/$(basename "$servico"): YAML inválido: $(tail -1 "$TMP/erro")"; continue
      fi
      ok "$nome/$(basename "$servico")"
    done
  done
  [[ $TEM_YAML == 1 ]] || echo "  (sem python3+yaml: só conferi as variáveis, não o YAML)"
fi

echo "== 5. despertador com gcloud simulado (como o real: rótulos do Cloud SQL só no beta)"
mkdir -p "$TMP/bin" "$TMP/estado"
cat > "$TMP/bin/gcloud" <<'FALSO'
#!/usr/bin/env bash
E="$ESTADO"; args="$*"; beta=0
[[ "$1" == beta ]] && { beta=1; shift; args="$*"; }
case "$args" in
  "sql operations list"*) cat "$E/pendente" ;;
  "sql operations wait"*)
    op=$(echo "$args" | awk '{print $4}')
    if [[ -f "$E/op-$op" ]]; then cat "$E/op-$op" > "$E/banco"; rm "$E/op-$op"; fi
    # como no Cloud SQL: o rótulo de um patch assíncrono só vale quando a operação termina
    if [[ -f "$E/op-$op-rotulo" ]]; then cat "$E/op-$op-rotulo" > "$E/rotulo"; rm "$E/op-$op-rotulo"; fi
    : > "$E/pendente" ;;
  "sql instances patch"*)
    if [[ "$args" == *labels* && $beta == 0 ]]; then echo "ERROR: unrecognized arguments: --*-labels" >&2; exit 2; fi
    if [[ "$args" == *"--async"* ]]; then
      op="op$RANDOM"
      if [[ "$args" =~ --activation-policy=([A-Z]+) ]]; then echo "${BASH_REMATCH[1]}" > "$E/op-$op"; fi
      if [[ "$args" == *"--remove-labels=acordado_ate"* ]]; then : > "$E/rotulo"; fi
      if [[ "$args" =~ --update-labels=acordado_ate=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}" > "$E/op-$op-rotulo"; fi
      echo "$op"; exit 0
    fi
    if [[ "$args" =~ --update-labels=acordado_ate=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}" > "$E/rotulo"; fi ;;
  "sql instances describe"*userLabels*) cat "$E/rotulo" ;;
  "sql instances describe"*activationPolicy*) cat "$E/banco" ;;
  "run services describe"*"--format=json"*) echo "{\"autoscaling.knative.dev/minScale\": \"$(cat "$E/min" 2>/dev/null || echo 0)\"}" ;;
  "run services describe"*) echo ok ;;
  "run services update"*) if [[ "$args" =~ --min-instances=([0-9]+) ]]; then echo "${BASH_REMATCH[1]}" > "$E/min"; fi ;;
esac
exit 0
FALSO
chmod +x "$TMP/bin/gcloud"
echo NEVER > "$TMP/estado/banco"; : > "$TMP/estado/rotulo"; : > "$TMP/estado/pendente"
despertador() {   # ação [horas] — AGORA_TESTE: madrugada (fora do horário); DIAS=0: nunca liga sozinho
  env ESTADO="$TMP/estado" PATH="$TMP/bin:$PATH" PROJETO=teste REGIAO=southamerica-east1 INSTANCIA_SQL=praia-db \
      SERVICOS=praia-keycloak DIAS=0 AGORA_TESTE=1795400000 bash "$RAIZ/gcp/despertador/despertador.sh" "$@" >"$TMP/saida" 2>&1
}
estado() { echo "banco=$(cat "$TMP/estado/banco") min=$(cat "$TMP/estado/min" 2>/dev/null || echo 0) rotulo=$(cat "$TMP/estado/rotulo")"; }
confere() {   # descrição esperado
  local atual; atual="$(estado)"
  if [[ "$atual" == "$2" ]]; then ok "$1"; else falha "$1: esperado [$2], ficou [$atual]"; sed 's/^/          /' "$TMP/saida"; fi
}
echo "op-anterior" > "$TMP/estado/pendente"
despertador acordar 2;  confere "acordar 2h fora do horário (com operação do banco em andamento)" "banco=ALWAYS min=1 rotulo=1795407200"
despertador verificar;  confere "verificar dentro do prazo mantém ligado" "banco=ALWAYS min=1 rotulo=1795407200"
despertador hibernar;   confere "hibernar desliga tudo e apaga o prazo" "banco=NEVER min=0 rotulo="
despertador verificar;  confere "verificar fora do horário mantém hibernado" "banco=NEVER min=0 rotulo="
# corrida: o "verificar" do agendamento roda enquanto um "acordar" manual ainda está ligando o banco.
# Antes, o prazo só era gravado no fim do acordar e esse verificar hibernava o ambiente que acabara de acordar.
echo ALWAYS > "$TMP/estado/op-acordando"; echo 1795407200 > "$TMP/estado/op-acordando-rotulo"
echo acordando > "$TMP/estado/pendente"
despertador verificar;  confere "verificar durante um acordar em andamento não hiberna" "banco=ALWAYS min=0 rotulo=1795407200"
despertador acordar 2;  confere "acordar com o banco já ligado renova o prazo e as instâncias" "banco=ALWAYS min=1 rotulo=1795407200"
despertador hibernar;   confere "hibernar de novo" "banco=NEVER min=0 rotulo="
if despertador acao-invalida; then falha "despertador aceitou ação inválida"; else ok "despertador recusa ação inválida"; fi

echo
if [[ $FALHAS -eq 0 ]]; then echo "Tudo certo."; else echo "$FALHAS falha(s)."; exit 1; fi
