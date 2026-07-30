#!/usr/bin/env bash
set -Eeuo pipefail
export AWS_PAGER=""

#############################################
# setup_glue_crawler.sh
#
# Setup do Glue Catalog para o Trabalho Final (TF) da disciplina
# Data Warehouse, Lakehouse e Data Mesh (FIAP MBA). Roda no Codespaces
# do aluno conectado a uma conta AWS Academy Learner Lab, depois que o
# setup_aluno.sh ja criou o bucket e fez upload dos 3 CSVs.
#
# O que faz (idempotente, pode rodar de novo sem quebrar):
#   1) Valida pre-requisitos: aws CLI e credenciais ativas (sts).
#   2) Descobre accountID/region.
#   3) Confirma que o bucket tf-aluno-<accountID> existe e tem
#      objetos nos 3 prefixos: bruto/clientes, bruto/pedidos,
#      bruto/pedidos_delta.
#   4) Cria o database Glue 'trabalho_final_aluno' (idempotente).
#   5) Cria o crawler 'crawler-trabalho-final-aluno' apontando para
#      s3://tf-aluno-<accountID>/bruto/ com role LabRole. Se ja
#      existir, faz update-crawler.
#   6) Inicia o crawler e faz polling do estado (ate 5 min).
#   7) Valida rigorosamente que o crawler criou as 3 tabelas
#      esperadas com nomes em PT (clientes, pedidos, pedidos_delta)
#      e schemas corretos (sem col0..col6 - header detectado).
#   8) Imprime sumario com proximos passos.
#
# Pre-requisitos:
#   - setup_aluno.sh ja foi rodado com sucesso (bucket + CSVs no S3).
#   - Credenciais AWS Academy Learner Lab validas.
#   - Permissao para Glue (CreateDatabase, CreateCrawler, StartCrawler,
#     GetTables) e PassRole para LabRole. LabRole cobre.
#
# Uso:
#   bash setup_glue_crawler.sh           # executa o setup
#   bash setup_glue_crawler.sh -h        # mostra ajuda e sai
#   bash setup_glue_crawler.sh --help    # idem
#############################################

#############################################
# Variaveis de configuracao
#############################################
BUCKET_PREFIX="tf-aluno"
DATABASE_NAME="trabalho_final_aluno"
CRAWLER_NAME="crawler-trabalho-final-aluno"
ROLE_NAME="LabRole"

# Polling do crawler.
POLL_INTERVAL_SEC=10
POLL_MAX_ITER=30   # 30 * 10s = 5 min

# Numero de chamadas progress() abaixo. Conferido manualmente.
TOTAL_STEPS=8
CURRENT_STEP=0

#############################################
# Funcoes utilitarias
#############################################
progress() {
  local msg="$1"
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local pct=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  printf "\n[%3d%%] %s\n" "$pct" "$msg"
}

die() {
  echo
  echo "ERRO: $1" >&2
  exit 1
}

on_error() {
  local lineno="$1"
  local cmd="$2"
  echo
  echo "ERRO: falha ao executar (linha $lineno): $cmd" >&2
  echo "Dica: verifique credenciais AWS, conectividade e permissoes do LabRole." >&2
  exit 1
}
trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

print_help() {
  cat <<'HELP'
setup_glue_crawler.sh - Setup do Glue Catalog para o Trabalho Final (FIAP MBA)

USO:
  bash setup_glue_crawler.sh           Executa o setup completo (idempotente).
  bash setup_glue_crawler.sh -h        Mostra esta ajuda e sai (nao executa nada).
  bash setup_glue_crawler.sh --help    Idem.

O QUE FAZ:
  1.  Valida credenciais AWS (sts get-caller-identity).
  2.  Descobre accountID e regiao.
  3.  Confere que o bucket tf-aluno-<accountID> existe e tem 1 CSV em cada
      um dos 3 prefixos: bruto/clientes, bruto/pedidos, bruto/pedidos_delta.
  4.  Cria o database Glue 'trabalho_final_aluno' (idempotente).
  5.  Cria/atualiza o crawler 'crawler-trabalho-final-aluno' apontando para
      s3://tf-aluno-<accountID>/bruto/ com role LabRole.
  6.  Inicia o crawler e aguarda terminar (polling ate 5 min).
  7.  Valida que vieram exatamente 3 tabelas em PT (clientes, pedidos,
      pedidos_delta) e que os schemas tem colunas esperadas (sem col0..col6
      indicando header nao detectado).
  8.  Imprime sumario.

PRE-REQUISITOS:
  - setup_aluno.sh ja executado (bucket + 3 CSVs no S3).
  - Conta AWS Academy Learner Lab com credenciais validas.
  - Role IAM LabRole disponivel (default no Learner Lab).

PROXIMOS PASSOS APOS O SETUP:
  Abrir o Athena e seguir o passo 5 do README (criar tabelas Iceberg).
HELP
}

# Trata flags ANTES de qualquer chamada AWS.
case "${1:-}" in
  -h|--help)
    print_help
    exit 0
    ;;
  "")
    ;;
  *)
    echo "ERRO: argumento desconhecido: $1" >&2
    echo
    print_help
    exit 2
    ;;
esac

# Confere que a aws CLI esta presente. Nao instala automaticamente -
# setup_aluno.sh ja faz isso, e este script roda DEPOIS dele.
command -v aws >/dev/null 2>&1 \
  || die "AWS CLI nao encontrado. Rode 'bash setup_aluno.sh' primeiro - ele instala o aws CLI."

#############################################
# Execucao
#############################################

progress "Validando credenciais AWS..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  die "Credenciais AWS invalidas ou expiradas. No Learner Lab, clique em 'AWS Details' e copie o bloco para ~/.aws/credentials. Depois confirme com: aws sts get-caller-identity"
fi
REGION="$(aws configure get region 2>/dev/null || true)"
if [[ -z "$REGION" ]]; then
  REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
fi
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
echo "Account ID: $ACCOUNT_ID"
echo "Regiao:     $REGION"

BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}"
S3_BASE="s3://${BUCKET}"
S3_TARGET_PATH="${S3_BASE}/bruto/"

progress "Verificando bucket e prefixos S3 ($S3_BASE/bruto/)..."
if ! aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  die "Bucket $S3_BASE nao existe ou nao esta acessivel. Rode 'bash scripts/setup_aluno.sh' primeiro."
fi

# Confere que cada prefixo tem pelo menos 1 objeto.
# Nao usa --max-items aqui porque ele suprime KeyCount no output
# (vira "None"). Ler Contents[0].Key e mais robusto.
for prefix in "bruto/clientes/" "bruto/pedidos/" "bruto/pedidos_delta/"; do
  first_key="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "$prefix" --query 'Contents[0].Key' --output text 2>/dev/null || echo "None")"
  if [[ "$first_key" == "None" || -z "$first_key" ]]; then
    die "Prefixo $S3_BASE/$prefix esta vazio. Rode 'bash scripts/setup_aluno.sh' primeiro - ele faz upload dos 3 CSVs."
  fi
  echo "  [OK] $S3_BASE/$prefix tem objetos (ex: $first_key)."
done

progress "Criando database Glue '$DATABASE_NAME' (idempotente)..."
db_create_err="$(mktemp)"
if aws glue create-database --database-input "{\"Name\":\"${DATABASE_NAME}\"}" >/dev/null 2>"$db_create_err"; then
  echo "  Database '$DATABASE_NAME' criado."
else
  msg="$(cat "$db_create_err")"
  if echo "$msg" | grep -qiE 'AlreadyExistsException'; then
    echo "  Database '$DATABASE_NAME' ja existe (idempotente)."
  else
    rm -f "$db_create_err"
    die "Falha ao criar database Glue. Detalhe: $msg"
  fi
fi
rm -f "$db_create_err"

progress "Criando/atualizando crawler '$CRAWLER_NAME'..."
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
CRAWLER_TARGETS="{\"S3Targets\":[{\"Path\":\"${S3_TARGET_PATH}\"}]}"

cr_err="$(mktemp)"
if aws glue create-crawler \
    --name "$CRAWLER_NAME" \
    --role "$ROLE_ARN" \
    --database-name "$DATABASE_NAME" \
    --targets "$CRAWLER_TARGETS" \
    --description "Crawler do Trabalho Final FIAP - le 3 CSVs sob bruto/ e cria 3 tabelas no Glue" \
    >/dev/null 2>"$cr_err"; then
  echo "  Crawler '$CRAWLER_NAME' criado."
else
  msg="$(cat "$cr_err")"
  if echo "$msg" | grep -qiE 'AlreadyExistsException'; then
    echo "  Crawler '$CRAWLER_NAME' ja existe - atualizando configuracao..."
    aws glue update-crawler \
      --name "$CRAWLER_NAME" \
      --role "$ROLE_ARN" \
      --database-name "$DATABASE_NAME" \
      --targets "$CRAWLER_TARGETS" \
      --description "Crawler do Trabalho Final FIAP - le 3 CSVs sob bruto/ e cria 3 tabelas no Glue" \
      >/dev/null
    echo "  Crawler atualizado."
  else
    rm -f "$cr_err"
    die "Falha ao criar/atualizar crawler. Detalhe: $msg"
  fi
fi
rm -f "$cr_err"

progress "Iniciando crawler..."
# Se o crawler ja estiver rodando (RUNNING ou STOPPING) o start-crawler falha
# com CrawlerRunningException. Tratamos como ok e seguimos pro polling.
sc_err="$(mktemp)"
if aws glue start-crawler --name "$CRAWLER_NAME" >/dev/null 2>"$sc_err"; then
  echo "  Crawler iniciado."
else
  msg="$(cat "$sc_err")"
  if echo "$msg" | grep -qiE 'CrawlerRunningException'; then
    echo "  Crawler ja estava rodando (idempotente). Seguindo para o polling."
  else
    rm -f "$sc_err"
    die "Falha ao iniciar crawler. Detalhe: $msg"
  fi
fi
rm -f "$sc_err"

progress "Aguardando crawler terminar (polling ate $((POLL_INTERVAL_SEC * POLL_MAX_ITER))s)..."
ITER=0
LAST_STATE=""
while (( ITER < POLL_MAX_ITER )); do
  ITER=$((ITER + 1))
  STATE="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.State' --output text 2>/dev/null || echo "UNKNOWN")"
  ELAPSED=$((ITER * POLL_INTERVAL_SEC))
  printf "  [%3ds] crawler estado: %s\n" "$ELAPSED" "$STATE"
  LAST_STATE="$STATE"
  if [[ "$STATE" == "READY" ]]; then
    break
  fi
  if [[ "$STATE" != "RUNNING" && "$STATE" != "STOPPING" ]]; then
    die "Crawler em estado inesperado: $STATE. Verifique no console Glue."
  fi
  sleep "$POLL_INTERVAL_SEC"
done

if [[ "$LAST_STATE" != "READY" ]]; then
  die "Crawler nao terminou em $((POLL_INTERVAL_SEC * POLL_MAX_ITER))s (ultimo estado: $LAST_STATE). Verifique no console Glue para diagnostico."
fi

# Confere que o ultimo run foi SUCCEEDED (READY pode acontecer apos FAIL tambem).
LAST_STATUS="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl.Status' --output text 2>/dev/null || echo "UNKNOWN")"
if [[ "$LAST_STATUS" != "SUCCEEDED" ]]; then
  err_msg="$(aws glue get-crawler --name "$CRAWLER_NAME" --query 'Crawler.LastCrawl.ErrorMessage' --output text 2>/dev/null || echo "")"
  die "Crawler terminou mas o ultimo run nao foi SUCCEEDED (status=$LAST_STATUS). Erro: $err_msg"
fi
echo "  Crawler READY. Ultimo run: SUCCEEDED."

progress "Validando tabelas e schemas criados pelo crawler..."

# 1) Conta tabelas - deve ser exatamente 3.
NUM_TABLES="$(aws glue get-tables --database-name "$DATABASE_NAME" --query 'length(TableList)' --output text 2>/dev/null || echo "0")"
if [[ "$NUM_TABLES" != "3" ]]; then
  TABLE_NAMES_DEBUG="$(aws glue get-tables --database-name "$DATABASE_NAME" --query 'TableList[].Name' --output text 2>/dev/null || echo "")"
  die "Esperado 3 tabelas em $DATABASE_NAME, encontrado $NUM_TABLES. Tabelas: [$TABLE_NAMES_DEBUG]. O crawler pode ter falhado parcialmente; verifique no console Glue."
fi

# 2) Lista nomes - devem ser EXATAMENTE clientes, pedidos, pedidos_delta.
TABLE_NAMES="$(aws glue get-tables --database-name "$DATABASE_NAME" --query 'TableList[].Name' --output text 2>/dev/null | tr '\t' '\n' | sort | tr '\n' ' ' | sed 's/ $//')"
EXPECTED_NAMES="clientes pedidos pedidos_delta"
if [[ "$TABLE_NAMES" != "$EXPECTED_NAMES" ]]; then
  # Caso comum: nomes em ingles (customers / orders) - aluno usou setup antigo.
  if echo "$TABLE_NAMES" | grep -qiE 'customers|orders'; then
    die "Detectadas tabelas com nomes em INGLES ($TABLE_NAMES). Voce provavelmente rodou setup_aluno.sh com versao antiga. Limpe e rode de novo:
  aws s3 rm $S3_BASE/ --recursive
  bash scripts/setup_aluno.sh
  bash scripts/setup_glue_crawler.sh"
  fi
  die "Nomes de tabela inesperados. Esperado: [$EXPECTED_NAMES]. Encontrado: [$TABLE_NAMES]. O crawler pode ter agrupado prefixos de forma diferente; confira no console Glue."
fi
echo "  [OK] 3 tabelas presentes: clientes, pedidos, pedidos_delta."

# 3) Valida schema de cada tabela.
EXPECTED_CLIENTES="id_cliente nome sobrenome ano_nascimento cidade estado segmento"
EXPECTED_PEDIDOS="id_pedido id_cliente data_pedido categoria_produto quantidade preco_unitario desconto frete"

validate_schema() {
  local table="$1"
  local expected_cols="$2"
  local expected_count="$3"

  local cols
  cols="$(aws glue get-table --database-name "$DATABASE_NAME" --name "$table" --query 'Table.StorageDescriptor.Columns[].Name' --output text 2>/dev/null | tr '\t' '\n' | tr '\n' ' ' | sed 's/ $//')"
  local actual_count
  actual_count="$(echo "$cols" | wc -w | tr -d ' ')"

  if [[ "$actual_count" != "$expected_count" ]]; then
    die "Schema de '$table' tem $actual_count colunas (esperado $expected_count). Colunas detectadas: [$cols]"
  fi

  # Header nao detectado: viraria col0, col1, col2...
  if echo "$cols" | grep -qE '\bcol[0-9]+\b'; then
    die "Schema de '$table' veio com colunas col0..col$((actual_count - 1)) (header nao detectado pelo crawler). Confira o CSV no S3 - a primeira linha precisa ser cabecalho."
  fi

  # Cada coluna esperada precisa estar presente.
  for c in $expected_cols; do
    if ! echo " $cols " | grep -qE " $c "; then
      die "Coluna obrigatoria '$c' ausente em '$table'. Colunas detectadas: [$cols]"
    fi
  done
  echo "  [OK] $table: $actual_count colunas, todas as esperadas presentes."
}

validate_schema "clientes"      "$EXPECTED_CLIENTES" 7
validate_schema "pedidos"       "$EXPECTED_PEDIDOS"  8
validate_schema "pedidos_delta" "$EXPECTED_PEDIDOS"  8

#############################################
# Sumario final
#############################################
echo
echo "============================================================"
echo "[100%] Concluido com sucesso."
echo "============================================================"
echo
echo "  Database:    $DATABASE_NAME"
echo "  Crawler:     $CRAWLER_NAME (READY)"
echo "  Tabelas:     clientes (7 cols), pedidos (8 cols), pedidos_delta (8 cols)"
echo
echo "  Proximo passo: Tarefa 3 do README (criar tabelas Iceberg no Athena)."
echo
