#!/usr/bin/env bash
set -Eeuo pipefail
export AWS_PAGER=""

#############################################
# setup_aluno.sh
#
# Setup do Trabalho Final (TF) da disciplina de Data Warehouse, Lakehouse
# e Data Mesh (FIAP MBA). Roda no Codespaces do aluno conectado a uma
# conta AWS Academy Learner Lab.
#
# O que faz (idempotente, pode rodar de novo sem quebrar):
#   1) Valida pre-requisitos (aws, python3, curl) e instala o que faltar
#      em Linux/macOS suportados.
#   2) Detecta a regiao AWS via aws-cli, env-var ou IMDS.
#   3) Descobre o accountID via STS.
#   4) Define o bucket: tf-aluno-<accountID>.
#   5) Cria o bucket S3 (se ja existir, segue em frente).
#   6) Prepara WORKDIR local (/tmp/tf-aluno-setup/dataset/).
#   7) Roda generate_dataset.py (vizinho deste script) para gerar 3 CSVs:
#        clientes.csv      (10001 linhas com cabecalho)
#        pedidos.csv       (100001 linhas com cabecalho)
#        pedidos_delta.csv (6 linhas com cabecalho)
#   8) Valida tamanho/contagem de linhas dos 3 CSVs.
#   9) Faz upload para o bucket em prefixos SEPARADOS:
#        s3://<bucket>/bruto/clientes/clientes.csv
#        s3://<bucket>/bruto/pedidos/pedidos.csv
#        s3://<bucket>/bruto/pedidos_delta/pedidos_delta.csv
#      (prefixos separados sao OBRIGATORIOS para o Glue Crawler criar
#      uma tabela por entidade na Tarefa 2 do README.)
#  10) Confirma que os 3 objetos existem no S3 e nao estao vazios.
#  11) Imprime sumario com proximos passos.
#
# Pre-requisitos:
#   - Conta AWS Academy Learner Lab ativa, com credenciais validas em
#     ~/.aws/credentials ou variaveis de ambiente AWS_*.
#   - Codespaces ou Linux/macOS com bash >= 4.
#   - Permissao para criar S3 bucket e fazer PutObject (LabRole cobre).
#
# Uso:
#   bash setup_aluno.sh           # executa o setup
#   bash setup_aluno.sh -h        # mostra ajuda e sai
#   bash setup_aluno.sh --help    # idem
#############################################

#############################################
# Variaveis de configuracao
#############################################
BUCKET_PREFIX="tf-aluno"
WORKDIR="/tmp/tf-aluno-setup"
DATASET_DIR="$WORKDIR/dataset"

# Numero de chamadas progress() abaixo. Conferido manualmente.
TOTAL_STEPS=11
CURRENT_STEP=0

# Linhas esperadas em cada CSV (incluindo cabecalho).
EXPECTED_CLIENTES_LINES=10001
EXPECTED_PEDIDOS_LINES=100001
EXPECTED_DELTA_LINES=6

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
setup_aluno.sh - Setup do Trabalho Final (FIAP MBA / Data Warehouse, Lakehouse e Data Mesh)

USO:
  bash setup_aluno.sh           Executa o setup completo (idempotente).
  bash setup_aluno.sh -h        Mostra esta ajuda e sai (nao executa nada).
  bash setup_aluno.sh --help    Idem.

O QUE FAZ:
  1.  Valida pre-requisitos (aws, python3, curl); instala o que faltar.
  2.  Detecta a regiao AWS (aws configure / env / IMDS).
  3.  Descobre o accountID via STS.
  4.  Define o bucket: tf-aluno-<accountID>.
  5.  Cria o bucket S3 (idempotente).
  6.  Prepara diretorio de trabalho local (/tmp/tf-aluno-setup/dataset).
  7.  Roda generate_dataset.py (vizinho deste script) para gerar 3 CSVs.
  8.  Valida contagem de linhas: clientes=10001, pedidos=100001, delta=6.
  9.  Faz upload em prefixos S3 separados:
        bruto/clientes/clientes.csv
        bruto/pedidos/pedidos.csv
        bruto/pedidos_delta/pedidos_delta.csv
 10.  Valida o upload (head-object dos 3 arquivos).
 11.  Imprime sumario e proximos passos (Tarefa 2: Glue Crawler).

PRE-REQUISITOS:
  - Conta AWS Academy Learner Lab com credenciais validas (aws sts get-caller-identity).
  - Codespaces ou Linux/macOS com bash >= 4.
  - Permissao para criar bucket S3 e PutObject (LabRole cobre).

VARIAVEIS RELEVANTES (definidas no inicio do script):
  BUCKET_PREFIX = tf-aluno
  WORKDIR       = /tmp/tf-aluno-setup
  DATASET_DIR   = /tmp/tf-aluno-setup/dataset

PROXIMOS PASSOS APOS O SETUP:
  Abrir o README do Trabalho Final e seguir a Tarefa 2 (criar Glue Crawler
  apontando para s3://tf-aluno-<accountID>/bruto/).
HELP
}

# Trata flags ANTES de qualquer chamada AWS / instalacao.
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

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatorio nao encontrado: $1 (instale e rode novamente)."
}

detect_os() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "macos"
  elif [[ -f /etc/os-release ]]; then
    if grep -qiE '^ID(_LIKE)?=.*(debian|ubuntu)' /etc/os-release; then
      echo "debian"
    elif grep -qiE '^ID(_LIKE)?=.*(rhel|centos|fedora|amzn)' /etc/os-release; then
      echo "rhel"
    else
      echo "linux"
    fi
  else
    echo "unknown"
  fi
}

sudo_if_needed() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Preciso de privilegios para instalar pacotes e 'sudo' nao esta disponivel. Rode como root ou instale manualmente."
  fi
}

pkg_install() {
  local os="$1"; shift
  echo "Instalando pacote(s): $*"
  case "$os" in
    debian)
      local waited=0
      while sudo_if_needed fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
         || sudo_if_needed fuser /var/lib/apt/lists/lock      >/dev/null 2>&1 \
         || sudo_if_needed fuser /var/lib/dpkg/lock           >/dev/null 2>&1; do
        if (( waited == 0 )); then
          echo "  -> apt em uso por outro processo. Aguardando liberar o lock..."
        fi
        sleep 3
        waited=$((waited + 3))
        if (( waited >= 120 )); then
          die "apt segue bloqueado apos 120s. Tente: sudo killall apt apt-get unattended-upgrade"
        fi
      done
      local APT_NET_OPTS=(
        -o Acquire::ForceIPv4=true
        -o Acquire::http::Timeout=30
        -o Acquire::https::Timeout=30
        -o Acquire::Retries=3
        -o Dpkg::Use-Pty=0
      )
      sudo_if_needed env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get "${APT_NET_OPTS[@]}" update -y
      sudo_if_needed env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a \
        apt-get "${APT_NET_OPTS[@]}" \
        -o Dpkg::Options::=--force-confold \
        -o Dpkg::Options::=--force-confdef \
        install -y --no-install-recommends "$@"
      ;;
    rhel)
      if command -v dnf >/dev/null 2>&1; then
        sudo_if_needed dnf install -y "$@"
      else
        sudo_if_needed yum install -y "$@"
      fi
      ;;
    macos)
      command -v brew >/dev/null 2>&1 || die "Homebrew nao encontrado. Instale em https://brew.sh/ e tente novamente."
      brew install "$@"
      ;;
    *)
      die "SO nao suportado para instalacao automatica: $os. Instale manualmente: $*"
      ;;
  esac
}

install_awscli() {
  local os="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  case "$os" in
    debian|rhel|linux)
      local arch url
      arch="$(uname -m)"
      if [[ "$arch" == "aarch64" || "$arch" == "arm64" ]]; then
        url="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
      else
        url="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
      fi
      command -v curl  >/dev/null 2>&1 || die "curl precisa estar disponivel antes de instalar o AWS CLI."
      command -v unzip >/dev/null 2>&1 || pkg_install "$os" unzip
      curl -fsSL "$url" -o "$tmpdir/awscliv2.zip"
      unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
      sudo_if_needed "$tmpdir/aws/install" --update >/dev/null
      ;;
    macos)
      curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "$tmpdir/AWSCLIV2.pkg"
      sudo_if_needed installer -pkg "$tmpdir/AWSCLIV2.pkg" -target /
      ;;
    *)
      die "SO nao suportado para instalacao automatica do AWS CLI: $os"
      ;;
  esac
  rm -rf "$tmpdir"
}

ensure_cmd() {
  local cmd="$1"
  local os="$2"
  if command -v "$cmd" >/dev/null 2>&1; then
    return 0
  fi
  echo "Comando '$cmd' nao encontrado - instalando automaticamente ($os)..."
  case "$cmd" in
    aws)     install_awscli "$os" ;;
    python3) pkg_install "$os" python3 ;;
    curl)    pkg_install "$os" curl ;;
    *)       pkg_install "$os" "$cmd" ;;
  esac
  command -v "$cmd" >/dev/null 2>&1 || die "Falha ao instalar '$cmd'. Instale manualmente e rode de novo."
}

detect_region() {
  local region=""
  region="$(aws configure get region 2>/dev/null || true)"
  if [[ -z "$region" ]]; then
    region="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
  fi
  if [[ -z "$region" ]]; then
    local token
    token="$(curl -sS -m 2 -X PUT "http://169.254.169.254/latest/api/token" \
      -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)"
    if [[ -n "$token" ]]; then
      region="$(curl -sS -m 2 -H "X-aws-ec2-metadata-token: $token" \
        "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null \
        | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    else
      region="$(curl -sS -m 2 "http://169.254.169.254/latest/dynamic/instance-identity/document" 2>/dev/null \
        | sed -n 's/.*"region"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    fi
  fi
  [[ -n "$region" ]] || die "Nao foi possivel detectar a regiao AWS. Defina AWS_DEFAULT_REGION ou rode: aws configure set region us-east-1"
  echo "$region"
}

ensure_bucket() {
  local bucket="$1"
  local region="$2"

  # Caso 1: o bucket ja eh nosso (head-bucket retorna 0).
  if aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1; then
    echo "Bucket ja existe e esta acessivel: s3://$bucket"
    return 0
  fi

  # Caso 2: nao esta acessivel - tenta criar. Se o nome ja for de outra
  # conta, o create-bucket falha com BucketAlreadyExists e o trap trata.
  echo "Criando bucket: s3://$bucket (regiao: $region)"
  local create_err
  create_err="$(mktemp)"
  if [[ "$region" == "us-east-1" ]]; then
    if ! aws s3api create-bucket --bucket "$bucket" >/dev/null 2>"$create_err"; then
      local msg
      msg="$(cat "$create_err")"
      rm -f "$create_err"
      if echo "$msg" | grep -qiE 'BucketAlreadyOwnedByYou'; then
        echo "Bucket ja era seu (BucketAlreadyOwnedByYou). Seguindo."
      elif echo "$msg" | grep -qiE 'BucketAlreadyExists'; then
        die "Nome do bucket '$bucket' ja existe em OUTRA conta AWS. Como o nome inclui o accountID, isso e raro - confirme que voce esta na conta certa. Detalhe: $msg"
      else
        die "Falha ao criar o bucket s3://$bucket. Detalhe: $msg"
      fi
    fi
  else
    if ! aws s3api create-bucket \
      --bucket "$bucket" \
      --create-bucket-configuration "LocationConstraint=$region" \
      >/dev/null 2>"$create_err"; then
      local msg
      msg="$(cat "$create_err")"
      rm -f "$create_err"
      if echo "$msg" | grep -qiE 'BucketAlreadyOwnedByYou'; then
        echo "Bucket ja era seu (BucketAlreadyOwnedByYou). Seguindo."
      elif echo "$msg" | grep -qiE 'BucketAlreadyExists'; then
        die "Nome do bucket '$bucket' ja existe em OUTRA conta AWS. Detalhe: $msg"
      else
        die "Falha ao criar o bucket s3://$bucket. Detalhe: $msg"
      fi
    fi
  fi
  rm -f "$create_err"

  aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 \
    || die "Bucket s3://$bucket nao esta acessivel apos a criacao. Verifique permissoes (LabRole) e regiao."
}

# Conta linhas de um CSV e compara com o esperado.
validate_csv_lines() {
  local file="$1"
  local expected="$2"
  local label="$3"

  [[ -f "$file" ]] || die "CSV esperado nao foi gerado: $file ($label)."
  [[ -s "$file" ]] || die "CSV gerado mas vazio: $file ($label)."

  local actual
  actual="$(wc -l < "$file" | tr -d ' ')"
  if [[ "$actual" != "$expected" ]]; then
    die "Contagem de linhas incorreta em $label ($file): esperado=$expected, obtido=$actual. Re-rode o setup ou verifique generate_dataset.py."
  fi
  echo "  [OK] $label: $actual linhas (incluindo cabecalho)."
}

#############################################
# Localizacao do generate_dataset.py
# (mesmo diretorio deste script, gerado em paralelo por outro agente)
#############################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENERATE_PY="$SCRIPT_DIR/generate_dataset.py"

#############################################
# Execucao
#############################################

progress "Validando pre-requisitos (aws, python3, curl) - instalando o que faltar..."
OS_FAMILY="$(detect_os)"
echo "SO detectado: $OS_FAMILY"
ensure_cmd curl    "$OS_FAMILY"
ensure_cmd python3 "$OS_FAMILY"
ensure_cmd aws     "$OS_FAMILY"
echo "AWS CLI: $(aws --version 2>&1)"
echo "Python:  $(python3 --version 2>&1)"

progress "Detectando regiao AWS..."
REGION="$(detect_region)"
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
echo "Regiao: $REGION"

progress "Obtendo accountID via STS..."
ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text 2>/dev/null || true)"
if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
  die "Credenciais AWS invalidas ou expiradas. No Learner Lab, clique em 'AWS Details' e copie de novo o bloco para ~/.aws/credentials. Depois confirme com: aws sts get-caller-identity"
fi
echo "Account ID: $ACCOUNT_ID"

progress "Definindo nomes dos recursos..."
BUCKET="${BUCKET_PREFIX}-${ACCOUNT_ID}"
S3_BASE="s3://${BUCKET}"
S3_CLIENTES="${S3_BASE}/bruto/clientes/clientes.csv"
S3_PEDIDOS="${S3_BASE}/bruto/pedidos/pedidos.csv"
S3_DELTA="${S3_BASE}/bruto/pedidos_delta/pedidos_delta.csv"
echo "Bucket alvo: $S3_BASE"
echo "Destinos:"
echo "  - $S3_CLIENTES"
echo "  - $S3_PEDIDOS"
echo "  - $S3_DELTA"

progress "Criando bucket S3 (idempotente)..."
ensure_bucket "$BUCKET" "$REGION"

progress "Preparando diretorio local de trabalho..."
mkdir -p "$DATASET_DIR"
# Limpa CSVs antigos para garantir que generate_dataset.py escreva fresh.
rm -f "$DATASET_DIR/clientes.csv" "$DATASET_DIR/pedidos.csv" "$DATASET_DIR/pedidos_delta.csv"
echo "WORKDIR: $WORKDIR"
echo "DATASET_DIR: $DATASET_DIR"

progress "Gerando CSVs com generate_dataset.py..."
[[ -f "$GENERATE_PY" ]] || die "generate_dataset.py nao encontrado em $SCRIPT_DIR. Verifique se o repositorio foi clonado completo (a pasta 04-Trabalho-Final/scripts/ deve conter os 2 arquivos: setup_aluno.sh e generate_dataset.py)."
echo "Rodando: python3 $GENERATE_PY $DATASET_DIR"
python3 "$GENERATE_PY" "$DATASET_DIR"

progress "Validando CSVs gerados (contagem de linhas)..."
validate_csv_lines "$DATASET_DIR/clientes.csv"       "$EXPECTED_CLIENTES_LINES" "clientes.csv"
validate_csv_lines "$DATASET_DIR/pedidos.csv"        "$EXPECTED_PEDIDOS_LINES"  "pedidos.csv"
validate_csv_lines "$DATASET_DIR/pedidos_delta.csv"  "$EXPECTED_DELTA_LINES"    "pedidos_delta.csv"

progress "Fazendo upload dos 3 CSVs em prefixos separados..."
# aws s3 cp sobrescreve por padrao - desejado, pois aluno pode rerodar
# o setup para "resetar" o bucket. Nao usamos sync para evitar deletar
# objetos do aluno por engano (--delete fica fora intencionalmente).
aws s3 cp "$DATASET_DIR/clientes.csv"      "$S3_CLIENTES" --only-show-errors
aws s3 cp "$DATASET_DIR/pedidos.csv"       "$S3_PEDIDOS"  --only-show-errors
aws s3 cp "$DATASET_DIR/pedidos_delta.csv" "$S3_DELTA"    --only-show-errors
echo "Upload concluido."

progress "Validando que os 3 objetos existem no S3..."
for s3_uri in "$S3_CLIENTES" "$S3_PEDIDOS" "$S3_DELTA"; do
  # Extrai key (tudo depois de s3://bucket/)
  key="${s3_uri#s3://${BUCKET}/}"
  size="$(aws s3api head-object --bucket "$BUCKET" --key "$key" --query 'ContentLength' --output text 2>/dev/null || echo "")"
  if [[ -z "$size" || "$size" == "None" || "$size" == "0" ]]; then
    die "Objeto S3 ausente ou vazio: $s3_uri"
  fi
  echo "  [OK] $s3_uri ($size bytes)"
done

#############################################
# Sumario final
#############################################
echo
echo "============================================================"
echo "[100%] Concluido com sucesso."
echo "============================================================"
echo
echo "  Account ID: $ACCOUNT_ID"
echo "  Regiao:     $REGION"
echo "  Bucket:     $S3_BASE"
echo
echo "  Prefixos com dados (1 CSV por entidade - padrao do Glue Crawler):"
echo "    $S3_BASE/bruto/clientes/"
echo "    $S3_BASE/bruto/pedidos/"
echo "    $S3_BASE/bruto/pedidos_delta/"
echo
echo "  Proximo passo: Tarefa 2 do README - criar Glue Crawler apontando para"
echo "    $S3_BASE/bruto/"
echo "  e rodar o crawler para criar 3 tabelas no Glue Data Catalog."
echo
