#!/usr/bin/env bash
# run_athena_sql.sh
# Roda um arquivo .sql no Athena, separando por ';' e executando cada
# statement individualmente. Faz polling do status e imprime o resultado
# (apenas para o ULTIMO statement, ou todos se VERBOSE=1).
#
# Uso:
#   ACCOUNT_ID=123456789012 ./run_athena_sql.sh path/to/script.sql
#   ACCOUNT_ID=123 VERBOSE=1 ./run_athena_sql.sh path/to/script.sql
#
# Variaveis (defaults para o trabalho final):
#   ACCOUNT_ID    obrigatorio (substitui <ACCOUNT_ID> nos SQLs)
#   DATABASE      trabalho_final_aluno
#   OUTPUT        s3://tf-aluno-${ACCOUNT_ID}/athena-results/
#   WORKGROUP     primary
#   AWS_PROFILE   testeredshift (export antes de chamar)

set -Eeuo pipefail
export AWS_PAGER=""

SQL_FILE="${1:?Uso: $0 path/to/script.sql}"
ACCOUNT_ID="${ACCOUNT_ID:?ACCOUNT_ID e obrigatorio}"
DATABASE="${DATABASE:-trabalho_final_aluno}"
OUTPUT="${OUTPUT:-s3://tf-aluno-${ACCOUNT_ID}/athena-results/}"
WORKGROUP="${WORKGROUP:-primary}"
VERBOSE="${VERBOSE:-0}"

[[ -f "$SQL_FILE" ]] || { echo "ERRO: arquivo nao encontrado: $SQL_FILE" >&2; exit 1; }

# Le SQL, substitui placeholders, remove comentarios de linha, e quebra por ';'
RAW=$(sed -e "s/<ACCOUNT_ID>/${ACCOUNT_ID}/g" "$SQL_FILE")

# Quebra por ';' preservando statements multi-linha
# Remove comentarios -- ate fim de linha (mas mantem strings com aspas)
PROCESSED=$(printf '%s\n' "$RAW" | python3 -c '
import sys, re
text = sys.stdin.read()
# Remove comentarios -- ate fim de linha
out = []
for line in text.split("\n"):
    # cuidado: nao remove se aspas; vamos assumir que SQL nao tem -- dentro de string
    idx = line.find("--")
    if idx >= 0:
        line = line[:idx]
    out.append(line)
text = "\n".join(out)
# Split por ; mas ignora ;s vazios
stmts = [s.strip() for s in text.split(";") if s.strip()]
for s in stmts:
    print(s + ";")
    print("--SPLIT--")
')

# Le statements
declare -a STATEMENTS=()
CURR=""
while IFS= read -r line; do
  if [[ "$line" == "--SPLIT--" ]]; then
    if [[ -n "$CURR" ]]; then
      STATEMENTS+=("$CURR")
    fi
    CURR=""
  else
    if [[ -z "$CURR" ]]; then
      CURR="$line"
    else
      CURR="$CURR
$line"
    fi
  fi
done <<< "$PROCESSED"

NUM=${#STATEMENTS[@]}
echo ">>> $SQL_FILE : $NUM statements"

LAST_QID=""
for i in "${!STATEMENTS[@]}"; do
  STMT="${STATEMENTS[$i]}"
  IDX=$((i+1))
  PREVIEW=$(echo "$STMT" | head -c 80 | tr '\n' ' ')
  echo "  [$IDX/$NUM] start: ${PREVIEW}..."

  QID=$(aws athena start-query-execution \
    --query-string "$STMT" \
    --query-execution-context "Database=${DATABASE}" \
    --result-configuration "OutputLocation=${OUTPUT}" \
    --work-group "${WORKGROUP}" \
    --query 'QueryExecutionId' --output text)

  LAST_QID="$QID"
  T0=$(date +%s)
  while true; do
    STATE=$(aws athena get-query-execution --query-execution-id "$QID" --query 'QueryExecution.Status.State' --output text)
    case "$STATE" in
      SUCCEEDED)
        ELAPSED=$(($(date +%s) - T0))
        echo "  [$IDX/$NUM] SUCCEEDED em ${ELAPSED}s (QID=$QID)"
        break
        ;;
      FAILED|CANCELLED)
        REASON=$(aws athena get-query-execution --query-execution-id "$QID" --query 'QueryExecution.Status.StateChangeReason' --output text)
        echo "  [$IDX/$NUM] $STATE (QID=$QID): $REASON" >&2
        exit 2
        ;;
      QUEUED|RUNNING)
        sleep 2
        ;;
      *)
        echo "  estado inesperado: $STATE" >&2
        sleep 2
        ;;
    esac
  done
done

echo "OK: $SQL_FILE concluido."
echo "LAST_QID=$LAST_QID"
