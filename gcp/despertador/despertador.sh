#!/usr/bin/env bash
# Despertador do ambiente: liga e desliga o que custa dinheiro parado.
#
# Roda como Cloud Run Job (imagem com gcloud), disparado a cada 15 min pelo Cloud Scheduler com a ação
# "verificar", e manualmente (atalhos acordar/hibernar) quando precisar fora do horário.
#
#   verificar         (padrão) no horário → garante tudo ligado; fora do horário → hiberna,
#                     a não ser que tenha sido acordado manualmente e o prazo ainda não venceu
#   acordar [HORAS]   liga agora; se estiver fora do horário, fica ligado por HORAS (padrão 3)
#                     e depois o próprio "verificar" hiberna de novo
#   hibernar          desliga agora (no horário, o próximo "verificar" liga de novo; para manter
#                     desligado o dia todo, pause o agendamento: gcloud scheduler jobs pause ...)
#   status            mostra o estado atual
#
# Ligar = banco ALWAYS + serviços com instância mínima. Hibernar = serviços com mínimo 0 + banco NEVER.
# Todas as ações são idempotentes: rodar de novo não muda nada se já estiver no estado certo.
set -euo pipefail

: "${PROJETO:?defina PROJETO}" "${REGIAO:?defina REGIAO}" "${INSTANCIA_SQL:?defina INSTANCIA_SQL}"
SERVICOS="${SERVICOS:-praia-keycloak}"
MIN_INSTANCIAS="${MIN_INSTANCIAS:-1}"
HORA_ACORDAR="${HORA_ACORDAR:-7}"
HORA_HIBERNAR="${HORA_HIBERNAR:-20}"
DIAS="${DIAS:-1234567}"
FUSO="${FUSO:-America/Sao_Paulo}"
ACAO="${1:-verificar}"
HORAS_EXTRAS="${2:-3}"

log() { echo "[despertador] $*"; }

# AGORA_TESTE (epoch) permite simular outro horário nos testes
AGORA="${AGORA_TESTE:-$(date +%s)}"
HORA=$((10#$(TZ="$FUSO" date -d "@$AGORA" +%H)))
DIA=$(TZ="$FUSO" date -d "@$AGORA" +%u)

em_horario() {
  [[ "$DIAS" == *"$DIA"* ]] && (( HORA >= HORA_ACORDAR && HORA < HORA_HIBERNAR ))
}

sql() { gcloud sql instances "$@" "$INSTANCIA_SQL" --project "$PROJETO" --quiet; }
# Rótulos (labels) do Cloud SQL só existem no "gcloud beta" (o patch normal recusa --update-labels/--remove-labels).
sql_beta() { gcloud beta sql instances "$@" "$INSTANCIA_SQL" --project "$PROJETO" --quiet; }

estado_banco() { sql describe --format='value(settings.activationPolicy)'; }

# Ligar/desligar o banco pode levar vários minutos, mais do que o gcloud espera por padrão ("is taking longer than
# expected" e erro, com a operação seguindo sozinha). Por isso: espera alguma operação que já esteja em andamento
# (ex.: o agendamento de 15 em 15 min rodando ao mesmo tempo), dispara a mudança sem bloquear e acompanha até 25 min.
ESPERA_BANCO_S="${ESPERA_BANCO_S:-1500}"
esperar_operacoes_do_banco() {
  local op
  for op in $(gcloud sql operations list --instance "$INSTANCIA_SQL" --project "$PROJETO" \
                --filter='status!=DONE' --format='value(name)' 2>/dev/null); do
    log "aguardando uma operação do banco que já estava em andamento..."
    gcloud beta sql operations wait "$op" --project "$PROJETO" --timeout="$ESPERA_BANCO_S" >/dev/null
  done
}
mudar_banco() {   # ALWAYS|NEVER [opções extras do patch, ex.: --remove-labels=...]
  local politica="$1" op; shift
  esperar_operacoes_do_banco
  op=$(sql_beta patch --activation-policy="$politica" "$@" --async --format='value(name)')
  # Desligar: ninguém precisa esperar o banco terminar de parar (são minutos à toa no job); a operação segue no
  # Google e a próxima execução espera por ela se precisar mexer no banco. Ligar: espera, os serviços dependem dele.
  if [[ "$politica" == NEVER ]]; then log "banco desligando (segue sozinho no Google)"; return; fi
  gcloud beta sql operations wait "$op" --project "$PROJETO" --timeout="$ESPERA_BANCO_S" >/dev/null
}

# Prazo (epoch) até quando o ambiente fica ligado fora do horário, guardado como label do Cloud SQL
acordado_ate() {
  local v
  v=$(sql describe --format='value(settings.userLabels.acordado_ate)')
  echo "${v:-0}"
}

min_atual() {
  gcloud run services describe "$1" --project "$PROJETO" --region "$REGIAO" --format=json 2>/dev/null \
    | grep -o '"autoscaling.knative.dev/minScale": *"[0-9]*"' | grep -o '[0-9]*"$' | tr -d '"' || true
}

servico_existe() {
  gcloud run services describe "$1" --project "$PROJETO" --region "$REGIAO" --format='value(metadata.name)' >/dev/null 2>&1
}

ajustar_min() {
  local servico="$1" alvo="$2" atual
  if ! servico_existe "$servico"; then log "$servico ainda não existe, ignorando"; return; fi
  atual=$(min_atual "$servico")
  if [[ -z "$atual" && "$alvo" == "0" ]]; then return; fi   # serviço sem mínimo definido = 0
  if [[ "$atual" != "$alvo" ]]; then
    log "$servico: instâncias mínimas ${atual:-0} -> $alvo"
    # --async: mudar o mínimo cria uma revisão nova e, sem isso, o gcloud espera ela ficar pronta (o Keycloak leva
    # até 3 min para subir; a API, mais um), um serviço de cada vez, até para desligar. O Cloud Run termina sozinho.
    gcloud run services update "$servico" --project "$PROJETO" --region "$REGIAO" \
      --min-instances="$alvo" --async --quiet >/dev/null
  fi
}

acordar() {   # [opções extras do patch, ex.: --update-labels=acordado_ate=...]
  # antes de olhar o estado: um desligamento ainda em andamento (o hibernar não espera) mudaria a resposta
  esperar_operacoes_do_banco
  if [[ "$(estado_banco)" != "ALWAYS" ]]; then
    log "ligando o banco (pode levar alguns minutos)..."
    mudar_banco ALWAYS "$@"
  elif [[ $# -gt 0 ]]; then
    sql_beta patch "$@" >/dev/null
  fi
  for s in ${SERVICOS//,/ }; do ajustar_min "$s" "$MIN_INSTANCIAS"; done
  log "ambiente LIGADO (banco pronto; Keycloak e API terminam de subir em 1-3 min)"
}

hibernar() {   # [verificar] — vindo do agendamento: desiste se alguém acordou o ambiente nesse meio-tempo
  for s in ${SERVICOS//,/ }; do ajustar_min "$s" 0; done
  esperar_operacoes_do_banco   # um "ligar" em andamento termina antes de olhar o estado
  if [[ "$(estado_banco)" != "NEVER" ]]; then
    if [[ "${1:-}" == verificar ]]; then
      if (( AGORA < $(acordado_ate) )); then
        log "acordado manualmente enquanto eu verificava, mantendo ligado"
        for s in ${SERVICOS//,/ }; do ajustar_min "$s" "$MIN_INSTANCIAS"; done
        return
      fi
    fi
    log "desligando o banco..."
    mudar_banco NEVER --remove-labels=acordado_ate
  fi
  log "ambiente HIBERNADO"
}

data_hora() { TZ="$FUSO" date -d "@$1" '+%d/%m %H:%M'; }

case "$ACAO" in
  acordar)
    # Fora do horário o prazo (rótulo acordado_ate) vai JUNTO com o "liga o banco", e não depois dele: ligar leva
    # vários minutos e o "verificar" do agendamento (a cada 15 min) que rodasse nesse intervalo não via prazo nenhum
    # e hibernava o ambiente de novo logo depois de acordar (e o CI seguia vendo o banco desligado e pulando o deploy).
    if em_horario; then
      acordar
    else
      ATE=$((AGORA + HORAS_EXTRAS * 3600))
      acordar --update-labels="acordado_ate=$ATE"
      log "fora do horário: fica ligado até $(data_hora "$ATE") e depois hiberna sozinho"
    fi
    ;;
  hibernar)
    hibernar
    ;;
  verificar)
    # um "acordar" manual em andamento termina primeiro (e grava o prazo) antes de decidir
    if ! em_horario; then esperar_operacoes_do_banco; fi
    ATE=$(acordado_ate)
    if em_horario; then
      acordar
    elif (( AGORA < ATE )); then
      log "acordado manualmente até $(data_hora "$ATE"), mantendo ligado"
    else
      hibernar verificar
    fi
    ;;
  status)
    ATE=$(acordado_ate)
    log "agora: $(data_hora "$AGORA") | horário automático: ${HORA_ACORDAR}h-${HORA_HIBERNAR}h, dias $DIAS"
    log "banco: $(estado_banco)"
    for s in ${SERVICOS//,/ }; do log "$s: instâncias mínimas $(min_atual "$s")"; done
    if (( ATE > AGORA )); then log "acordado manualmente até $(data_hora "$ATE")"; fi
    ;;
  *)
    echo "uso: despertador.sh [verificar|acordar [HORAS]|hibernar|status]" >&2
    exit 2
    ;;
esac
