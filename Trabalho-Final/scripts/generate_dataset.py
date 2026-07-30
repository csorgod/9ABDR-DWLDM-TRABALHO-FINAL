#!/usr/bin/env python3
"""
generate_dataset.py — gera os 3 CSVs sinteticos do trabalho final.

O QUE FAZ
=========
Gera tres arquivos CSV:
  clientes.csv       — 10.000 linhas
  pedidos.csv        — 100.000 linhas
  pedidos_delta.csv  — 5 linhas (3 inserts + 2 updates)

USO
===
    python3 generate_dataset.py <output_dir>

Ex:
    python3 generate_dataset.py /tmp/dataset

REQUISITOS
==========
Python 3.10+. Sem dependencias externas (apenas stdlib).
"""

import argparse
import csv
import hashlib
import random
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Constantes — ordem importa! Listas (nao set/dict) para garantir
# reprodutibilidade entre execucoes e versoes do Python.
# ---------------------------------------------------------------------------

SEED = 42

N_CLIENTES = 10_000
N_PEDIDOS = 100_000

# 50 nomes proprios brasileiros comuns (lista ordenada — nao mexer)
NOMES = [
    "Ana", "Bruno", "Carla", "Daniel", "Eduarda", "Felipe", "Gabriela",
    "Henrique", "Isabela", "Joao", "Karina", "Leonardo", "Mariana",
    "Nelson", "Olivia", "Patricia", "Rafael", "Sabrina", "Thiago",
    "Ursula", "Vinicius", "Wagner", "Yasmin", "Adriana", "Beatriz",
    "Caio", "Debora", "Eduardo", "Fernanda", "Gustavo", "Heloisa",
    "Igor", "Juliana", "Kelvin", "Larissa", "Marcelo", "Natalia",
    "Otavio", "Paula", "Renato", "Silvia", "Tatiana", "Ulisses",
    "Vanessa", "Wellington", "Xavier", "Yago", "Zilda", "Andre",
    "Bianca",
]

# 50 sobrenomes brasileiros comuns
SOBRENOMES = [
    "Silva", "Santos", "Oliveira", "Souza", "Rodrigues", "Ferreira",
    "Alves", "Pereira", "Lima", "Gomes", "Costa", "Ribeiro", "Martins",
    "Carvalho", "Almeida", "Lopes", "Soares", "Fernandes", "Vieira",
    "Barbosa", "Rocha", "Dias", "Nunes", "Mendes", "Moreira", "Cardoso",
    "Teixeira", "Correia", "Cavalcanti", "Pinto", "Ramos", "Araujo",
    "Monteiro", "Castro", "Andrade", "Cunha", "Freitas", "Morais",
    "Borges", "Reis", "Macedo", "Tavares", "Marques", "Pires", "Pacheco",
    "Moura", "Coelho", "Sampaio", "Brito", "Aragao",
]

# 27 capitais brasileiras (cidade, UF) — ordem fixa pela UF para estabilidade
CAPITAIS = [
    ("Rio Branco", "AC"),
    ("Maceio", "AL"),
    ("Macapa", "AP"),
    ("Manaus", "AM"),
    ("Salvador", "BA"),
    ("Fortaleza", "CE"),
    ("Brasilia", "DF"),
    ("Vitoria", "ES"),
    ("Goiania", "GO"),
    ("Sao Luis", "MA"),
    ("Cuiaba", "MT"),
    ("Campo Grande", "MS"),
    ("Belo Horizonte", "MG"),
    ("Belem", "PA"),
    ("Joao Pessoa", "PB"),
    ("Curitiba", "PR"),
    ("Recife", "PE"),
    ("Teresina", "PI"),
    ("Rio de Janeiro", "RJ"),
    ("Natal", "RN"),
    ("Porto Alegre", "RS"),
    ("Porto Velho", "RO"),
    ("Boa Vista", "RR"),
    ("Florianopolis", "SC"),
    ("Sao Paulo", "SP"),
    ("Aracaju", "SE"),
    ("Palmas", "TO"),
]

SEGMENTOS = ["VAREJO", "CORPORATIVO", "PME", "GOVERNO", "EDUCACAO"]

CATEGORIAS = [
    "ELETRONICOS", "MODA", "LIVROS", "CASA",
    "ESPORTE", "BELEZA", "ALIMENTOS",
]

# Faixa de datas para os pedidos (inclusive nos dois extremos).
# 2023-01-01 ate 2024-12-31 = 731 dias.
DATA_PEDIDO_INICIO_ORDINAL = 738521  # date(2023, 1, 1).toordinal()
DATA_PEDIDO_FIM_ORDINAL = 739251     # date(2024, 12, 31).toordinal()


# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

def md5_of_file(path: Path) -> str:
    """MD5 hexdigest de um arquivo, lido em chunks (defensivo, mesmo que
    nossos CSVs caibam tranquilamente em memoria)."""
    h = hashlib.md5()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def ordinal_to_iso(ordinal: int) -> str:
    """Converte um ordinal (date.toordinal()) para 'YYYY-MM-DD' sem usar
    objetos date — implementacao estavel entre versoes Python."""
    from datetime import date  # import local: usado so aqui
    return date.fromordinal(ordinal).isoformat()


# ---------------------------------------------------------------------------
# Geracao dos datasets
# ---------------------------------------------------------------------------

def gerar_clientes(rng: random.Random) -> list[dict]:
    """Gera 10.000 clientes.

    Cada id_cliente segue o formato C00001 .. C10000 (sequencial, nao
    aleatorio — facilita debug e a query do trabalho final).

    A coluna ano_nascimento (INT, 1950..2005) existe por dois motivos:
      1. Garante que a 1a linha do CSV (cabecalho) tem coluna numerica,
         o que faz o Glue Crawler detectar header automaticamente sem
         precisar de classifier customizado.
      2. Enriquece a query executiva (idade media do top 5).
    A ordem de chamadas rng.choice(...) NAO mudou; o randint do
    ano_nascimento e adicionado depois do sobrenome para nao quebrar o
    pareto (que depende do id_cliente permanecer C00001..C10000)."""
    clientes = []
    for i in range(1, N_CLIENTES + 1):
        cidade, uf = rng.choice(CAPITAIS)
        # ATENCAO: a ordem dos rng.* importa para reprodutibilidade.
        # Mantemos cidade/uf primeiro (mesma posicao da v1), depois
        # nome/sobrenome/ano_nascimento/segmento. ano_nascimento e gerado
        # APOS sobrenome para que o ano nao "consuma" o estado do rng
        # antes do cidade/uf — preservando pareto.
        nome = rng.choice(NOMES)
        sobrenome = rng.choice(SOBRENOMES)
        ano_nascimento = rng.randint(1950, 2005)
        segmento = rng.choice(SEGMENTOS)
        clientes.append({
            "id_cliente": f"C{i:05d}",
            "nome": nome,
            "sobrenome": sobrenome,
            "ano_nascimento": ano_nascimento,
            "cidade": cidade,
            "estado": uf,
            "segmento": segmento,
        })
    return clientes


def construir_pesos_pareto(rng: random.Random) -> list[float]:
    """Distribui 'peso de compra' entre os 10.000 clientes seguindo curva
    Pareto (alpha=1.16 — regra 80/20 classica). Resultado: ~20% dos
    clientes concentram ~80% dos pedidos. Garante que existem clientes
    'top 5' claramente distintos para a query final.

    Os pesos sao bruto-aleatorios e DEPOIS ordenados por id_cliente
    (ou seja, NAO ordenados por peso) — caso contrario o C00001 seria
    sempre o maior comprador, o que daria spoiler do resultado da query.
    """
    pesos = [rng.paretovariate(1.16) for _ in range(N_CLIENTES)]
    return pesos


def gerar_pedidos(rng: random.Random, pesos_clientes: list[float]) -> list[dict]:
    """Gera 100.000 pedidos. Distribuicao de id_cliente segue a curva
    Pareto pre-computada — o random.choices ja retorna proporcional ao
    peso, sem necessidade de normalizar."""
    ids_clientes = [f"C{i:05d}" for i in range(1, N_CLIENTES + 1)]

    # Sorteia todos os ids_clientes de uma vez (mais rapido e
    # consistente com o estado do rng).
    sorteados = rng.choices(ids_clientes, weights=pesos_clientes, k=N_PEDIDOS)

    pedidos = []
    for i in range(1, N_PEDIDOS + 1):
        id_cli = sorteados[i - 1]
        # Datas: ordinal aleatorio entre os dois limites (inclusivos)
        date_ord = rng.randint(DATA_PEDIDO_INICIO_ORDINAL, DATA_PEDIDO_FIM_ORDINAL)
        data_pedido = ordinal_to_iso(date_ord)

        quantidade = rng.randint(1, 10)
        preco_unitario = round(rng.uniform(10.00, 1000.00), 2)
        desconto = round(rng.uniform(0.00, 0.30), 2)
        frete = round(rng.uniform(5.00, 50.00), 2)

        pedidos.append({
            "id_pedido": f"O{i:06d}",
            "id_cliente": id_cli,
            "data_pedido": data_pedido,
            "categoria_produto": rng.choice(CATEGORIAS),
            "quantidade": quantidade,
            "preco_unitario": f"{preco_unitario:.2f}",
            "desconto": f"{desconto:.2f}",
            "frete": f"{frete:.2f}",
        })
    return pedidos


def gerar_delta(pedidos: list[dict]) -> list[dict]:
    """Gera 5 deltas hardcoded:
      - 3 INSERTs: O100001, O100002, O100003 (ids inexistentes em pedidos.csv)
      - 2 UPDATEs: usa os ids_pedido dos 2 PRIMEIROS pedidos de pedidos.csv,
        com desconto aumentado representando ajuste pos-fechamento.

    Linhas fixas — nao usa rng. O aluno enxerga este arquivo
    como 'os 5 deltas que vieram do fim do dia'.
    """
    p1 = pedidos[0]  # primeiro pedido (sera atualizado)
    p2 = pedidos[1]  # segundo pedido (sera atualizado)

    deltas = [
        # 3 INSERTs — ids_pedido 100.001 / 002 / 003 (nao existem em pedidos.csv)
        {
            "id_pedido": "O100001",
            "id_cliente": "C00001",
            "data_pedido": "2024-12-31",
            "categoria_produto": "ELETRONICOS",
            "quantidade": "5",
            "preco_unitario": "899.90",
            "desconto": "0.10",
            "frete": "29.90",
        },
        {
            "id_pedido": "O100002",
            "id_cliente": "C00042",
            "data_pedido": "2024-12-31",
            "categoria_produto": "MODA",
            "quantidade": "3",
            "preco_unitario": "149.00",
            "desconto": "0.05",
            "frete": "15.00",
        },
        {
            "id_pedido": "O100003",
            "id_cliente": "C09999",
            "data_pedido": "2024-12-31",
            "categoria_produto": "LIVROS",
            "quantidade": "2",
            "preco_unitario": "59.90",
            "desconto": "0.00",
            "frete": "12.00",
        },
        # 2 UPDATEs — mesmos ids_pedido do pedidos.csv, mas com desconto alterado
        {
            "id_pedido": p1["id_pedido"],
            "id_cliente": p1["id_cliente"],
            "data_pedido": p1["data_pedido"],
            "categoria_produto": p1["categoria_produto"],
            "quantidade": str(p1["quantidade"]),
            "preco_unitario": p1["preco_unitario"],
            "desconto": "0.50",  # ajuste de pos-fechamento
            "frete": p1["frete"],
        },
        {
            "id_pedido": p2["id_pedido"],
            "id_cliente": p2["id_cliente"],
            "data_pedido": p2["data_pedido"],
            "categoria_produto": p2["categoria_produto"],
            "quantidade": str(p2["quantidade"]),
            "preco_unitario": p2["preco_unitario"],
            "desconto": "0.45",
            "frete": p2["frete"],
        },
    ]
    return deltas


# ---------------------------------------------------------------------------
# I/O
# ---------------------------------------------------------------------------

def escrever_csv(path: Path, fieldnames: list[str], rows: list[dict]) -> None:
    """Escreve CSV utf-8 com cabecalho. Newline='' evita linhas em branco
    extras no Windows; o csv module cuida do line terminator."""
    with path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=fieldnames,
            quoting=csv.QUOTE_MINIMAL,
            lineterminator="\n",
        )
        writer.writeheader()
        writer.writerows(rows)


# ---------------------------------------------------------------------------
# Orquestracao
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Gera os 3 CSVs sinteticos do trabalho final.",
    )
    parser.add_argument(
        "output_dir",
        help="Diretorio onde os CSVs serao gravados (sera criado se nao existir).",
    )
    args = parser.parse_args()

    print("[1/5] Validando argumentos e diretorio de saida...")
    out_dir = Path(args.output_dir)
    try:
        out_dir.mkdir(parents=True, exist_ok=True)
    except OSError as e:
        print(
            f"ERRO: diretorio {out_dir} nao existe e nao foi possivel criar ({e}).",
            file=sys.stderr,
        )
        return 1
    if not out_dir.is_dir():
        print(f"ERRO: {out_dir} existe mas nao e um diretorio.", file=sys.stderr)
        return 1

    clientes_path = out_dir / "clientes.csv"
    pedidos_path = out_dir / "pedidos.csv"
    delta_path = out_dir / "pedidos_delta.csv"

    # rng UNICO para todo o processo — cada chamada consome do mesmo
    # estado, mantendo a sequencia reprodutivel.
    rng = random.Random(SEED)

    print(f"[2/5] Gerando clientes.csv ({N_CLIENTES} linhas)...")
    clientes = gerar_clientes(rng)
    escrever_csv(
        clientes_path,
        ["id_cliente", "nome", "sobrenome", "ano_nascimento", "cidade", "estado", "segmento"],
        clientes,
    )

    print(f"[3/5] Gerando pedidos.csv ({N_PEDIDOS} linhas)...")
    pesos = construir_pesos_pareto(rng)
    pedidos = gerar_pedidos(rng, pesos)
    escrever_csv(
        pedidos_path,
        [
            "id_pedido", "id_cliente", "data_pedido", "categoria_produto",
            "quantidade", "preco_unitario", "desconto", "frete",
        ],
        pedidos,
    )

    print("[4/5] Gerando pedidos_delta.csv (5 linhas hardcoded)...")
    deltas = gerar_delta(pedidos)
    escrever_csv(
        delta_path,
        [
            "id_pedido", "id_cliente", "data_pedido", "categoria_produto",
            "quantidade", "preco_unitario", "desconto", "frete",
        ],
        deltas,
    )

    print("[5/5] Calculando md5sum dos arquivos...")
    md5_clientes = md5_of_file(clientes_path)
    md5_pedidos = md5_of_file(pedidos_path)
    md5_delta = md5_of_file(delta_path)

    print()
    print(f"OK. Arquivos gerados em {out_dir}:")
    print(f"  clientes.csv       ({N_CLIENTES} linhas, md5: {md5_clientes})")
    print(f"  pedidos.csv        ({N_PEDIDOS} linhas, md5: {md5_pedidos})")
    print(f"  pedidos_delta.csv  (5 linhas, md5: {md5_delta})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
