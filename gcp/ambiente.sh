#!/usr/bin/env bash
# Carrega a configuração de um ambiente. Usado pelos outros scripts:
#   source "$(dirname "$0")/ambiente.sh" homologacao|producao
# O ambiente é OBRIGATÓRIO (sem padrão), para ninguém publicar na produção sem querer.
# Em produção, rodando num terminal (não no GitHub Actions), pede para digitar o ID do projeto.

_AMBIENTE="${1:-${AMBIENTE:-}}"
_PASTA_AMBIENTES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ambientes"

if [[ "$_AMBIENTE" != "homologacao" && "$_AMBIENTE" != "producao" ]]; then
  echo "Informe o ambiente: homologacao ou producao (ex.: bash gcp/deploy.sh homologacao)" >&2
  exit 1
fi
source "$_PASTA_AMBIENTES/$_AMBIENTE.env"

if [[ "$PROJETO" == troque-pelo-id-do-projeto* ]]; then
  echo "Ajuste PROJETO em gcp/ambientes/$_AMBIENTE.env" >&2
  exit 1
fi

if [[ "$AMBIENTE" == "producao" && -z "${CI:-}" && -t 0 ]]; then
  echo "ATENÇÃO: você está mexendo na PRODUÇÃO ($PROJETO)."
  read -r -p "Digite o ID do projeto para confirmar: " _confirmacao
  [[ "$_confirmacao" == "$PROJETO" ]] || { echo "Cancelado."; exit 1; }
fi
unset _AMBIENTE _PASTA_AMBIENTES _confirmacao
