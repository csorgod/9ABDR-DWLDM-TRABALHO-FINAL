# Trabalho Final — Lakehouse Iceberg para TPCH Trading

Disciplina: Data Warehouse, Lakehouse e Data Mesh (FIAP)
Referência: [04-Trabalho-Final](https://github.com/vamperst/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/tree/master/04-Trabalho-Final)

## Objetivo

Construir um pipeline lakehouse ponta a ponta no Amazon Athena, transformando um data lake tradicional (Hive external) em um lakehouse transacional baseado em Apache Iceberg, aplicando deltas de CDC diários sem reescrever a tabela inteira.

## Output Esperado (Entregáveis)

Arquivo final: `trabalho-final.zip`, com a estrutura exata abaixo, enviado no portal FIAP.

```
trabalho-final/
├── sql/
│   ├── 01_create_iceberg_tables.sql
│   ├── 02_insert_data.sql
│   ├── 03_add_calculated_column.sql
│   ├── 04_merge_delta.sql
│   ├── 05_optimize.sql
│   └── 06_query_executiva.sql
├── prints/
│   ├── 01_show_create_iceberg.png
│   ├── 02_count_apos_merge.png   (deve mostrar 100003 linhas)
│   └── 03_top5_clientes.png
└── DECISION.md
```

### Resultados que os artefatos devem comprovar

| Artefato | O que precisa mostrar |
|---|---|
| `01_create_iceberg_tables.sql` + print `01_show_create_iceberg.png` | `SHOW CREATE TABLE` das tabelas `clientes_iceberg` e `pedidos_iceberg`, confirmando `table_type=iceberg` |
| `02_insert_data.sql` | Carga de 10.000 clientes e 100.000 pedidos (com `CAST` de `data_pedido` para `DATE`) |
| `03_add_calculated_column.sql` | Coluna `valor_final` adicionada via `ALTER TABLE` e populada via `UPDATE` |
| `04_merge_delta.sql` + print `02_count_apos_merge.png` | `MERGE INTO` aplicando 3 inserts + 2 updates do delta; contagem final = **100.003** linhas |
| `05_optimize.sql` | `OPTIMIZE ... REWRITE DATA USING BIN_PACK` + `VACUUM` executados |
| `06_query_executiva.sql` + print `03_top5_clientes.png` | Top 5 clientes por receita total (JOIN clientes + pedidos, `SUM`/`AVG`/`COUNT`) |
| `DECISION.md` | ADR defendendo uma decisão técnica de evolução para 100x o volume (ex.: particionamento), com alternativas descartadas, razões e métricas de validação |

### Critérios de avaliação
- Pipeline executa sem erros e com os dados esperados
- Compreensão conceitual de Iceberg vs. Hive external (schema-on-read vs. schema-on-write)
- Uso correto de DDL/DML (INSERT, UPDATE, MERGE, ALTER)
- ADR coerente, com trade-offs explícitos
- Estrutura do zip exatamente conforme especificado

## Divisão de Tarefas (4 pessoas)

| Pessoa | Responsabilidade | Entregáveis |
|---|---|---|
| **Pessoa 1 — Infra & Provisionamento** | Rodar `setup_aluno.sh` e `setup_glue_crawler.sh`, validar credenciais AWS (`aws sts get-caller-identity`), confirmar catalogação das 3 tabelas raw no Glue, e cuidar da limpeza final da AWS (`aws s3 rm/rb`) após a entrega | Ambiente provisionado e validado; execução da limpeza pós-entrega |
| **Pessoa 2 — Criação & Carga (Tarefas 3-4)** | Escrever e executar o DDL das tabelas Iceberg (`clientes_iceberg`, `pedidos_iceberg`) e o `INSERT INTO ... SELECT` com conversão de tipos | `01_create_iceberg_tables.sql`, `02_insert_data.sql`, print `01_show_create_iceberg.png` |
| **Pessoa 3 — Evolução de Schema & CDC (Tarefas 5-6)** | Adicionar e popular `valor_final` via `ALTER TABLE` + `UPDATE`; criar tabela intermediária do delta e executar o `MERGE INTO` (3 inserts + 2 updates) | `03_add_calculated_column.sql`, `04_merge_delta.sql`, print `02_count_apos_merge.png` |
| **Pessoa 4 — Otimização, Query Executiva & ADR (Tarefas 7-9)** | Rodar `OPTIMIZE`/`VACUUM`; escrever e executar a query dos top 5 clientes; redigir o `DECISION.md` (com input do grupo sobre a decisão técnica escolhida) | `05_optimize.sql`, `06_query_executiva.sql`, print `03_top5_clientes.png`, `DECISION.md` |

**Observação**: todas as pessoas devem revisar o `DECISION.md` antes da entrega, já que é uma decisão de grupo. A montagem final do zip e o upload no portal FIAP ficam sob responsabilidade de quem finalizar por último (sugestão: Pessoa 4, já que depende dos artefatos anteriores).

## Prazos

- Finalização técnica: sexta-feira
- Envio no portal FIAP: antes da deadline da turma (tipicamente domingo à noite)
- Limpeza dos recursos AWS: imediatamente após a entrega, para preservar o budget do Learner Lab
