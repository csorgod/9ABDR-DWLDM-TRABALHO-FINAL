# 04 - Trabalho Final: Lakehouse Iceberg para a TPCH Trading

> **Quinta-feira, 14h. Última semana do trimestre.**
> Você é engenheiro de dados na **TPCH Trading**, distribuidora B2B com sede em São Paulo. **Marina (CFO)** te chama no Slack:
>
> > *— "Preciso fechar a apresentação para o conselho na sexta. Quero **top 5 clientes por receita líquida** com nome, cidade e segmento. Mas tem um detalhe: o time comercial fechou ajustes de última hora ontem à noite — 3 pedidos novos e 2 com desconto corrigido. Preciso desses ajustes refletidos no número final."*
>
> Você tem CSVs no S3, Athena à disposição, e exatamente **um dia** para entregar uma tabela Iceberg que aceite tanto a carga inicial quanto os deltas de CDC sem reescrever o mundo a cada batch. **Esse é o trabalho final.**

Este é o **trabalho final avaliativo** da disciplina. **É um trabalho em grupo** (composição definida pelo professor da turma). Vocês vão construir, juntos, um pipeline lakehouse ponta a ponta no Athena: provisionam o S3, geram dados sintéticos, catalogam via Glue Crawler, materializam em Iceberg, evoluem o esquema, aplicam delta com `MERGE INTO`, otimizam arquivos e entregam a query executiva. No final, defendem uma decisão técnica de evolução em um documento curto (estilo ADR).

> [!IMPORTANT]
> **Trabalho em grupo — não individual.** Combinem entre si quem roda os scripts no Codespaces de quem (a infra é provisionada uma vez, na conta AWS Academy de **um integrante** do grupo). A entrega é única para o grupo: um zip só, subido no portal por um dos membros.

> [!WARNING]
> **Pré-requisitos obrigatórios antes de começar:**
>
> - [ ] Credenciais AWS Academy atualizadas no Codespaces — ver [Preparando Credenciais](../00-create-codespaces/Inicio-de-aula.md)
> - [ ] Codespaces da disciplina aberto com terminal funcional
> - [ ] Você concluiu os Labs 02.1 e 02.2 (Iceberg básico + MERGE/OPTIMIZE) — eles são pré-requisito conceitual
> - [ ] Você consegue acessar o [console do Amazon Athena](https://us-east-1.console.aws.amazon.com/athena/home?region=us-east-1#/landing-page) e o [console do AWS Glue](https://us-east-1.console.aws.amazon.com/glue/home?region=us-east-1#/v2/data-catalog/databases)
>
> **Valide rapidamente:**
>
> ```bash
> aws sts get-caller-identity
> ```
>
> Se retornar JSON com `Account` e `Arn`, você está pronto. Anote o `Account` (12 dígitos) — você vai usar nos SQLs.
>
> **Tempo estimado total: 3h–4h** (execução pura ~25 min + tempo para você escrever os SQLs do zero, observar resultados, debugar e escrever o `DECISION.md` ao final).

## O que você vai fazer

Você é responsável por entregar **3 coisas** para a Marina:

1. Uma tabela Iceberg `pedidos_iceberg` consolidada e auditável.
2. A query executiva: top 5 clientes por receita líquida.
3. Um documento `DECISION.md` defendendo uma decisão técnica de evolução, caso a TPCH cresça 100×.

Não vamos te dar os SQLs prontos. **Você escreve o pipeline inteiro**, usando o que aprendeu nos Labs 02.x e 03.x como referência. O gabarito existe (e o professor o usa), mas você só consulta depois de tentar.

## Arquitetura

![Arquitetura do trabalho final](img/arquitetura-trabalho-final.png)

O diagrama mostra o fluxo ponta a ponta do trabalho: (1) o **setup** roda no Codespaces e materializa 3 CSVs sintéticos no S3; (2) a **camada bruto** vive em prefixos separados por entidade dentro de `tf-aluno-<ACCOUNT_ID>`; (3) o **Glue Crawler** cataloga os 3 CSVs como tabelas externas, e o **Athena** transforma esses raws em tabelas **Iceberg** (`clientes_iceberg`, `pedidos_iceberg`, `pedidos_delta_iceberg`) via `CREATE TABLE` + `INSERT`/CTAS, evolui o esquema com `ALTER TABLE ADD COLUMNS`, aplica o delta de CDC via `MERGE INTO` e mantém a saúde da tabela com `OPTIMIZE` + `VACUUM`; (4) a **query executiva** faz `JOIN` entre as duas Iceberg para devolver o top 5 clientes por receita líquida, e o `DECISION.md` em ADR fecha o entregável para a Marina.

Fonte editável: [`img/arquitetura-trabalho-final.drawio`](img/arquitetura-trabalho-final.drawio).

## Principais pontos de aprendizagem

- provisionamento mínimo via shell script (S3 + dataset sintético)
- catalogação automática com **Glue Crawler** (CSV → tabela Hive externa)
- materialização Iceberg com `CREATE TABLE` + `INSERT INTO ... SELECT`
- conversão de tipo na carga (`CAST(data_pedido AS DATE)`)
- evolução de esquema (`ALTER TABLE ... ADD COLUMNS`) + `UPDATE` que materializa coluna calculada
- aplicação de CDC via **`MERGE INTO`** com tabela Iceberg intermediária
- manutenção de tabela Iceberg com `OPTIMIZE` (BIN_PACK) e `VACUUM`
- entrega analítica (top N) e justificativa técnica em ADR

## O que você terá ao final

Uma tabela `pedidos_iceberg` populada com **100.003 pedidos** (100k iniciais + 3 inseridos via MERGE), uma query que devolve os 5 maiores clientes por receita líquida, e um `DECISION.md` defendendo como você evoluiria o lakehouse se a TPCH crescesse 100×. Tudo isso empacotado em um `.zip` e enviado no **portal FIAP** da sua turma — o formato de entrega é parte do trabalho (Tarefa 10).

> [!TIP]
> Sempre que encontrar um bloco com o título **💡 Clique para entender**, abra esse trecho. Ele traz explicação detalhada do contexto e dicas de como abordar a tarefa — sem dar o SQL pronto.

## Modelo de dados final no Athena

São **6 tabelas** organizadas em **3 grupos**: 3 raws criadas pelo Glue Crawler, 2 Iceberg principais (entrega final) e 1 Iceberg auxiliar usada só no MERGE.

### Fluxo entre os grupos

```mermaid
flowchart LR
    subgraph RAW["🟦 RAW · Glue Crawler (Tarefa 2)"]
        direction TB
        R1[clientes]
        R2[pedidos]
        R3[pedidos_delta]
    end

    subgraph ICE_AUX["🟧 ICEBERG AUXILIAR · só para o MERGE (Tarefa 6)"]
        direction TB
        A1[pedidos_delta_iceberg]
    end

    subgraph ICE_MAIN["🟩 ICEBERG PRINCIPAIS · entregáveis (Tarefas 3-7)"]
        direction TB
        I1[clientes_iceberg]
        I2[pedidos_iceberg]
    end

    R1 -- "INSERT INTO<br/>Tarefa 4" --> I1
    R2 -- "INSERT INTO<br/>+ CAST data_pedido<br/>Tarefa 4" --> I2
    R3 -- "CTAS<br/>+ valor_final<br/>Tarefa 6" --> A1
    A1 -- "MERGE INTO<br/>(3 INS + 2 UPD)<br/>Tarefa 6" --> I2
    I1 -. "JOIN id_cliente<br/>Tarefa 8" .- I2

    classDef raw fill:#DBEAFE,stroke:#1E40AF,color:#1E3A8A
    classDef iceMain fill:#D1FAE5,stroke:#065F46,color:#064E3B
    classDef iceAux fill:#FED7AA,stroke:#9A3412,color:#7C2D12

    class R1,R2,R3 raw
    class I1,I2 iceMain
    class A1 iceAux
```

**Legenda:**

- 🟦 **RAW** — `clientes`, `pedidos`, `pedidos_delta`. Criadas pelo **Glue Crawler** na Tarefa 2 (formato CSV, externa). O Crawler usa o nome da pasta-pai (`s3://tf-aluno-<ACCOUNT_ID>/bruto/<entidade>/`) como nome da tabela. Tipos: tudo `STRING`/`INT`/`DOUBLE` por inferência. **Não vão para a entrega** — são intermediárias.
- 🟩 **ICEBERG PRINCIPAIS** — `clientes_iceberg`, `pedidos_iceberg`. Criadas com `CREATE TABLE` + `TBLPROPERTIES('table_type'='iceberg', ...)` (Parquet + ZSTD) e populadas com `INSERT INTO ... SELECT` (Tarefa 4). `pedidos_iceberg` ainda recebe `ALTER TABLE ADD COLUMNS valor_final` + `UPDATE` (Tarefa 5) e o `MERGE INTO` dos deltas (Tarefa 6). **São essas duas tabelas que respondem a query executiva** da Tarefa 8.
- 🟧 **ICEBERG AUXILIAR** — `pedidos_delta_iceberg`. Criada via CTAS na Tarefa 6 só para alimentar o `MERGE INTO`. **Pode ser dropada após o MERGE** — não entra em consultas analíticas.

### Detalhe de cada tabela (colunas)

```mermaid
erDiagram
    clientes {
        string id_cliente "RAW · Glue Crawler"
        string nome
        string sobrenome
        int ano_nascimento
        string cidade
        string estado
        string segmento
    }
    pedidos {
        string id_pedido "RAW · Glue Crawler"
        string id_cliente
        string data_pedido "STRING (vai virar DATE)"
        string categoria_produto
        bigint quantidade
        double preco_unitario
        double desconto
        double frete
    }
    pedidos_delta {
        string id_pedido "RAW · 3 INSERTs + 2 UPDATEs"
        string id_cliente
        string data_pedido "STRING"
        string categoria_produto
        bigint quantidade
        double preco_unitario
        double desconto
        double frete
    }

    clientes_iceberg {
        string id_cliente PK "ICEBERG PRINCIPAL"
        string nome
        string sobrenome
        int ano_nascimento
        string cidade
        string estado
        string segmento
    }
    pedidos_iceberg {
        string id_pedido PK "ICEBERG PRINCIPAL"
        string id_cliente FK
        date data_pedido "convertido na CTAS"
        string categoria_produto
        bigint quantidade
        double preco_unitario
        double desconto
        double frete
        double valor_final "ALTER+UPDATE Tarefa 5"
    }
    pedidos_delta_iceberg {
        string id_pedido "ICEBERG AUXILIAR (descartavel)"
        string id_cliente
        date data_pedido
        string categoria_produto
        bigint quantidade
        double preco_unitario
        double desconto
        double frete
        double valor_final "calculado na CTAS"
    }

    clientes ||--|| clientes_iceberg : "1- INSERT INTO (Tarefa 4)"
    pedidos ||--|| pedidos_iceberg : "2- INSERT INTO + CAST data_pedido (Tarefa 4)"
    pedidos_delta ||--|| pedidos_delta_iceberg : "3- CTAS + valor_final (Tarefa 6)"
    pedidos_delta_iceberg }o--|| pedidos_iceberg : "4- MERGE INTO 3 INS + 2 UPD (Tarefa 6)"
    clientes_iceberg ||--o{ pedidos_iceberg : "5- JOIN id_cliente (Tarefa 8)"
```

A primeira coluna de descrição em cada tabela diz a **categoria** (RAW / ICEBERG PRINCIPAL / ICEBERG AUXILIAR), batendo com as cores do flowchart acima. Os relacionamentos estão numerados na **ordem de execução** (1 → 5) para você seguir o fluxo cronologicamente.

## Mapa do trabalho

O trabalho está organizado em **3 fases**:

- 🧰 **Fase A — Provisionamento (Tarefas 1-2):** automatizada por scripts. Você só roda 2 comandos no terminal e segue para a Fase B. Não há SQL para escrever aqui.
- 🛠️ **Fase B — Desenvolvimento do trabalho (Tarefas 3-9):** **é onde o trabalho realmente acontece.** Aqui você escreve os SQLs no Athena, materializa a coluna calculada, aplica o MERGE, otimiza, responde a query executiva e escreve o `DECISION.md`.
- 📦 **Fase C — Entrega e limpeza (Tarefas 10-11):** monta o zip, sobe no portal FIAP e limpa os recursos AWS.

| Fase | Tarefa | O que você faz | Passos | Tempo |
|------|--------|----------------|--------|-------|
| 🧰 A | [Tarefa 1](#tarefa-1---provisionamento-do-bucket-e-dataset) | Provisiona bucket S3 e gera os 3 CSVs | [1](#passo-1) · [2](#passo-2) · [3](#passo-3) | ~10 min |
| 🧰 A | [Tarefa 2](#tarefa-2---catalogar-no-glue-com-crawler) | Roda script que cria database + crawler e valida 3 tabelas raw | [4](#passo-4) | ~5 min |
| 🛠️ B | [Tarefa 3](#tarefa-3---criar-tabelas-iceberg-vazias) | DDL Iceberg: `clientes_iceberg` + `pedidos_iceberg` | [5](#passo-5) · [6](#passo-6) · [7](#passo-7) | ~15 min |
| 🛠️ B | [Tarefa 4](#tarefa-4---carregar-dados-iniciais) | `INSERT INTO ... SELECT` com `CAST(data_pedido AS DATE)` | [8](#passo-8) · [9](#passo-9) | ~15 min |
| 🛠️ B | [Tarefa 5](#tarefa-5---adicionar-coluna-calculada-valor_final) | `ALTER TABLE` + `UPDATE` materializando `valor_final` | [10](#passo-10) · [11](#passo-11) · [12](#passo-12) | ~15 min |
| 🛠️ B | [Tarefa 6](#tarefa-6---aplicar-delta-de-cdc-com-merge-into) | CTAS Iceberg do delta + `MERGE INTO` | [13](#passo-13) · [14](#passo-14) · [15](#passo-15) | ~25 min |
| 🛠️ B | [Tarefa 7](#tarefa-7---otimizar-a-tabela) | `OPTIMIZE` (BIN_PACK) + `VACUUM` | [16](#passo-16) · [17](#passo-17) · [18](#passo-18) | ~15 min |
| 🛠️ B | [Tarefa 8](#tarefa-8---entrega-da-query-executiva) | Top 5 clientes por receita líquida | [19](#passo-19) · [20](#passo-20) | ~10 min |
| 🛠️ B | [Tarefa 9](#tarefa-9---escrever-decisionmd) | Defender a evolução técnica em ADR | [21](#passo-21) | ~30 min |
| 📦 C | [Tarefa 10](#tarefa-10---empacotar-e-enviar-no-portal-fiap) | Monta o zip de entrega e sobe no portal FIAP | [22](#passo-22) · [23](#passo-23) | ~10 min |
| 📦 C | [Tarefa 11](#tarefa-11---limpeza) | Limpa S3 + Glue para preservar budget Learner Lab | [24](#passo-24) | ~5 min |

> [!TIP]
> Se travou em algum passo, clique no número correspondente acima.

---

<details>
<summary><b>💡 O que é um Lakehouse Iceberg em 3 parágrafos</b></summary>
<blockquote>

**Data lake puro** = arquivos Parquet/CSV no S3, catalogados como tabela Hive externa. Funciona para `SELECT` e `INSERT`, mas não tem `UPDATE`, `DELETE`, time travel ou evolução de esquema sem reescrever a tabela inteira. Era o que a TPCH tinha antes deste projeto.

**Lakehouse com Iceberg** = mesmo armazenamento (S3 + Parquet), mas com **camada de metadados transacional** que rastreia snapshots, manifests e deletes. Cada `INSERT` / `UPDATE` / `MERGE` gera um snapshot novo; o anterior fica consultável via time travel. `OPTIMIZE` reorganiza arquivos sem alterar dados de negócio. Iceberg é open-source e suportado nativamente pelo Athena.

**Por que isso importa para a Marina** — o pedido dela ("aplicar 5 deltas e ver o resultado consolidado") é trivial em DW tradicional (uma `MERGE` no Redshift) e impossível em data lake puro. Iceberg traz a transacionalidade do DW para o S3, com custo de storage do lake. Esse é o ponto da disciplina inteira.

Documentação oficial:
- [Apache Iceberg specification](https://iceberg.apache.org/spec/)
- [Querying Iceberg tables in Athena](https://docs.aws.amazon.com/athena/latest/ug/querying-iceberg.html)
- [MERGE INTO no Athena](https://docs.aws.amazon.com/athena/latest/ug/merge-into-statement.html)

</blockquote>
</details>

## Contexto

A **TPCH Trading** consolidou os pedidos do ano em um CSV no S3 e está prestes a virar a chave do data lake atual (Hive table) para um lakehouse Iceberg. A Marina precisa, na sexta, que o relatório executivo (top 5 clientes) reflita os ajustes de CDC do dia anterior. Você tem hoje (quinta) para entregar uma tabela Iceberg que:

1. Carregue os 100k pedidos do CSV principal (`pedidos.csv`).
2. Tenha uma coluna calculada `valor_final = quantidade * preco_unitario * (1 - desconto) + frete`.
3. Aceite um delta diário de CDC sem reescrever a tabela inteira.
4. Possa ser auditada (snapshots) e otimizada (compactação).

O dataset é sintético e ja vem pronto: o setup gera os 3 CSVs e faz upload no seu bucket.

---

## Tarefa 1 - Provisionamento do bucket e dataset

### Resultado esperado desta tarefa

Um bucket `s3://tf-aluno-<ACCOUNT_ID>/` com 3 CSVs em prefixos separados:

- `s3://tf-aluno-<ACCOUNT_ID>/bruto/clientes/clientes.csv` (10.000 linhas)
- `s3://tf-aluno-<ACCOUNT_ID>/bruto/pedidos/pedidos.csv` (100.000 linhas)
- `s3://tf-aluno-<ACCOUNT_ID>/bruto/pedidos_delta/pedidos_delta.csv` (5 linhas)

---

<a id="passo-1"></a>

**1.** No Codespaces da disciplina, abra um terminal integrado e vá para a pasta do trabalho final:

```bash
cd /workspaces/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/04-Trabalho-Final
```

<a id="passo-2"></a>

**2.** Rode o setup. Ele detecta seu account ID, cria o bucket `tf-aluno-<ACCOUNT_ID>`, gera os 3 CSVs e faz upload em prefixos separados:

```bash
bash scripts/setup_aluno.sh
```

Saída esperada (resumo dos últimos passos):

```
[100%] Concluido com sucesso.
  Account ID: 123456789012
  Bucket:     s3://tf-aluno-123456789012
  Prefixos com dados (1 CSV por entidade - padrao do Glue Crawler):
    s3://tf-aluno-123456789012/bruto/clientes/
    s3://tf-aluno-123456789012/bruto/pedidos/
    s3://tf-aluno-123456789012/bruto/pedidos_delta/
```

<details>
<summary><b>💡 Clique para entender: por que prefixos separados por entidade?</b></summary>
<blockquote>

O **Glue Crawler** (Tarefa 2) usa o caminho do prefixo como heurística para decidir se dois objetos são "a mesma tabela" ou "tabelas diferentes". Se você jogar `clientes.csv` e `pedidos.csv` no mesmo prefixo, ele cria UMA tabela com schema misturado (e quebra). Por isso o `setup_aluno.sh` força:

```
bruto/clientes/clientes.csv
bruto/pedidos/pedidos.csv
bruto/pedidos_delta/pedidos_delta.csv
```

Cada subpasta = uma tabela no catálogo. Esse é o padrão clássico de organização de bucket para Glue Crawler.

</blockquote>
</details>

<a id="passo-3"></a>

**3.** Confirme que os 3 objetos existem no S3:

```bash
aws s3 ls s3://tf-aluno-$(aws sts get-caller-identity --query Account --output text)/bruto/ --recursive
```

Saída esperada (3 linhas, com `clientes.csv`, `pedidos.csv`, `pedidos_delta.csv`).

<details>
<summary><b>⚠ Se der erro: <code>Unable to locate credentials</code></b></summary>
<blockquote>

Suas credenciais AWS Academy expiraram (validade ~4h por sessão). No Learner Lab, clique em **AWS Details** → copie o bloco `[default]` para `~/.aws/credentials` e rode novamente. Confirme com `aws sts get-caller-identity`.

</blockquote>
</details>

### Checkpoint

- [ ] Bucket `tf-aluno-<ACCOUNT_ID>` criado
- [ ] 3 CSVs no S3, em prefixos separados sob `bruto/`
- [ ] `aws s3 ls` mostra os 3 arquivos com tamanhos > 0

---

## Tarefa 2 - Catalogar no Glue com Crawler

### Resultado esperado desta tarefa

Um **database Glue** chamado `trabalho_final_aluno` com **3 tabelas raw** (Hive external) catalogadas: `clientes`, `pedidos`, `pedidos_delta`. Cada uma aponta para o CSV correspondente em `s3://tf-aluno-<ACCOUNT_ID>/bruto/<entidade>/`.

> [!IMPORTANT]
> O crawler vai varrer `s3://.../bruto/` inteiro. Como o `setup_aluno.sh` colocou 3 entidades em subpastas separadas, o crawler **cria 3 tabelas** — uma por entidade, **com o nome da pasta-pai** (sem sufixo `_raw`). Confirme isso ao final desta tarefa.

---

<a id="passo-4"></a>

**4.** Rode o script de setup do Glue Crawler. Ele cria o database `trabalho_final_aluno`, cria o crawler apontando para `s3://tf-aluno-<ACCOUNT_ID>/bruto/`, dispara a execução, **espera o crawler terminar** (~1-2 min) e **valida que as 3 tabelas vieram com os schemas esperados**:

```bash
cd /workspaces/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/04-Trabalho-Final && \
  bash scripts/setup_glue_crawler.sh
```

Saída esperada (final do log):

```
[100%] Concluido com sucesso.

  Database:    trabalho_final_aluno
  Crawler:     crawler-trabalho-final-aluno (READY)
  Tabelas:     clientes (7 cols), pedidos (8 cols), pedidos_delta (8 cols)
```

<details>
<summary><b>💡 Clique para entender: o que o script faz por baixo</b></summary>
<blockquote>

Em vez de você criar database + crawler manualmente no console (3-4 minutos com risco de errar prefixo S3, esquecer LabRole etc.), o script automatiza:

1. Valida credenciais e que o bucket existe
2. `aws glue create-database` (idempotente)
3. `aws glue create-crawler` apontando para `s3://tf-aluno-<ACCOUNT_ID>/bruto/` com role `LabRole`
4. `aws glue start-crawler` e faz polling do estado a cada 10s até `READY`
5. Lista as tabelas criadas e valida nomes (`clientes`, `pedidos`, `pedidos_delta`) e schemas (colunas em PT, sem `col0..col6` indicando header não detectado)

Se algum check falhar, o script para com mensagem clara apontando o que aconteceu — e você (ou o professor olhando o log) sabe exatamente onde corrigir.

Para conferir visualmente o resultado, abra o [console do AWS Glue](https://us-east-1.console.aws.amazon.com/glue/home?region=us-east-1#/v2/data-catalog/databases) → **Databases** → `trabalho_final_aluno` → **Tables**. Você verá as 3 tabelas. Em `pedidos`, `data_pedido` deve estar como `string` (o Crawler infere CSV como string por padrão — vamos converter para `DATE` na Tarefa 4); em `clientes`, `ano_nascimento` deve estar como `int`.

</blockquote>
</details>

<details>
<summary><b>⚠ Se der erro: <code>tabelas com nomes em ingles (customers/orders) detectadas</code></b></summary>
<blockquote>

Você rodou o `setup_aluno.sh` com uma versão antiga deste repo (em inglês). Limpe o bucket e rerrode o setup atual:

```bash
aws s3 rm s3://tf-aluno-$(aws sts get-caller-identity --query Account --output text)/ --recursive
cd /workspaces/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/04-Trabalho-Final && \
  bash scripts/setup_aluno.sh && \
  bash scripts/setup_glue_crawler.sh
```

</blockquote>
</details>

<details>
<summary><b>⚠ Se der erro: <code>Crawler nao terminou em 300s</code> ou <code>LastCrawl.Status != SUCCEEDED</code></b></summary>
<blockquote>

Causa típica: a role `LabRole` não tem permissão para ler algum prefixo, ou a estrutura do S3 mudou (CSVs ausentes/vazios). Investigue no [console Glue → Crawlers → `crawler-trabalho-final-aluno` → CloudWatch logs](https://us-east-1.console.aws.amazon.com/glue/home?region=us-east-1#/v2/etl-configuration/crawlers).

Se for "no objects in S3 path", rerrode `bash scripts/setup_aluno.sh` para garantir os 3 CSVs no bucket, e depois `bash scripts/setup_glue_crawler.sh`.

</blockquote>
</details>

### Checkpoint

- [ ] Database `trabalho_final_aluno` existe no Glue
- [ ] 3 tabelas raw catalogadas (`clientes`, `pedidos`, `pedidos_delta`)
- [ ] Schemas em PT (sem `col0..col6` indicando header não detectado)
- [ ] Script terminou com `[100%] Concluido com sucesso`

---

---

> [!IMPORTANT]
> 🛠️ **Aqui começa o trabalho que vocês vão desenvolver.** As Tarefas 1 e 2 acima eram só provisionamento automatizado. Daqui em diante (Tarefas 3-9) é onde vocês escrevem os SQLs no Athena, aplicam as transformações e produzem os entregáveis. **É essa fase que o professor avalia.**

## Tarefa 3 - Criar tabelas Iceberg vazias

### Resultado esperado desta tarefa

Duas tabelas Iceberg **vazias** no database `trabalho_final_aluno`:

- `clientes_iceberg` — schema final dos clientes
- `pedidos_iceberg` — schema dos pedidos, **com `data_pedido` já como `DATE`** (vamos converter na carga)

A `LOCATION` de cada tabela aponta para `s3://tf-aluno-<ACCOUNT_ID>/iceberg/<entidade>/`.

---

> [!IMPORTANT]
> **Account ID:** os SQLs daqui para frente têm `<ACCOUNT_ID>` em `LOCATION 's3://tf-aluno-<ACCOUNT_ID>/...'`. Pegue o seu uma única vez no terminal e tenha à mão para substituir:
>
> ```bash
> aws sts get-caller-identity --query Account --output text
> ```
>
> Saída: 12 dígitos. Use "Find & Replace" do editor para trocar nos SQLs antes de colar no Athena. O nome do bucket que você criou na Tarefa 1 já carrega esse valor (`tf-aluno-XXXXXXXXXXXX`) — pode pegar de lá também via `aws s3 ls | grep tf-aluno`.

<a id="passo-5"></a>

**5.** No [console do Athena](https://us-east-1.console.aws.amazon.com/athena/home?region=us-east-1#/landing-page), clique em **Editor de consultas**, selecione o database `trabalho_final_aluno` no painel esquerdo e configure o **Resultado da consulta** para `s3://tf-aluno-<ACCOUNT_ID>/athena-results/` (substitua seu account ID).

> 💡 **Apoio:** o setup do Athena com bucket de resultados foi feito passo a passo no [Lab 02.1, Parte 2](../02-Open-Table-Format/01-Funcionalidades-Basicas/README.md). Se travar aqui, releia esses passos.

<details>
<summary><b>💡 Para usuários avançados: rodar SQLs via terminal em vez do console</b></summary>
<blockquote>

Se você prefere automatizar (debug iterativo, comparação entre execuções), use o script `scripts/run_athena_sql.sh` deste repo. Ele lê um `.sql`, substitui `<ACCOUNT_ID>` automaticamente, quebra em statements e roda um por um, com polling de status. Salve seu SQL em qualquer caminho (ex: `~/meus_sqls/01_create.sql`) e rode:

```bash
cd /workspaces/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/04-Trabalho-Final && \
  bash scripts/run_athena_sql.sh ~/meus_sqls/01_create.sql
```

Saída: cada statement reporta `start → SUCCEEDED em Xs` (ou `FAILED` com motivo).

Para o trabalho avaliativo, o caminho oficial continua sendo escrever os SQLs do zero no console — o script é apenas para acelerar iterações.

</blockquote>
</details>

<a id="passo-6"></a>

**6.** Crie a tabela `clientes_iceberg`. Dica: use `CREATE TABLE` (sem `EXTERNAL`) com `TBLPROPERTIES ('table_type'='iceberg', ...)`. Schema:

> 💡 **Apoio:** o `CREATE TABLE` Iceberg com `TBLPROPERTIES` idêntico ao que você precisa aqui está no [Lab 02.1 — Funcionalidades Básicas (Parte 3 — Criando a base Iceberg)](../02-Open-Table-Format/01-Funcionalidades-Basicas/README.md#parte-3---criando-a-base-iceberg).

| Coluna | Tipo |
|--------|------|
| id_cliente | STRING |
| nome | STRING |
| sobrenome | STRING |
| ano_nascimento | INT |
| cidade | STRING |
| estado | STRING |
| segmento | STRING |

LOCATION: `s3://tf-aluno-<ACCOUNT_ID>/iceberg/clientes/`

<details>
<summary><b>💡 Clique para entender: padrão de criação de tabela Iceberg no Athena</b></summary>
<blockquote>

A sintaxe é a do Lab 02.1 / 02.2:

```sql
CREATE TABLE <db>.<tabela> (
    col1 TIPO,
    col2 TIPO,
    ...
)
LOCATION 's3://...'
TBLPROPERTIES (
  'table_type'='iceberg',
  'format'='PARQUET',
  'write_compression'='zstd'
);
```

Sem `EXTERNAL`, sem `STORED AS`. O `table_type='iceberg'` é o que faz o Athena tratar a tabela como Iceberg em vez de Hive externa.

</blockquote>
</details>

<a id="passo-7"></a>

**7.** Crie a tabela `pedidos_iceberg` com o schema abaixo. **Atenção**: `data_pedido` é **`DATE`** aqui (não `STRING` como na raw — vamos fazer o `CAST` na carga):

| Coluna | Tipo |
|--------|------|
| id_pedido | STRING |
| id_cliente | STRING |
| data_pedido | **DATE** |
| categoria_produto | STRING |
| quantidade | INT |
| preco_unitario | DOUBLE |
| desconto | DOUBLE |
| frete | DOUBLE |

LOCATION: `s3://tf-aluno-<ACCOUNT_ID>/iceberg/pedidos/`

<details>
<summary><b>⚠ Se der erro: <code>HIVE_TABLE_BAD_DATA</code> ou semelhante</b></summary>
<blockquote>

Se rodar `SELECT * FROM pedidos_iceberg` agora, deve retornar 0 linhas (a tabela foi criada vazia). Se aparecer erro de schema, releia o DDL — provavelmente um tipo está com nome errado (`STRING` é STRING, não `VARCHAR`).

</blockquote>
</details>

### Checkpoint

- [ ] `SHOW TABLES IN trabalho_final_aluno;` lista as 2 tabelas Iceberg + as 3 raw (5 no total)
- [ ] `DESCRIBE pedidos_iceberg` mostra `data_pedido date` (não `string`)
- [ ] `SELECT COUNT(*) FROM pedidos_iceberg` retorna `0`

---

## Tarefa 4 - Carregar dados iniciais

### Resultado esperado desta tarefa

`clientes_iceberg` com **10.000 linhas**; `pedidos_iceberg` com **100.000 linhas** e `data_pedido` populada como `DATE`.

---

<a id="passo-8"></a>

**8.** Carregue `clientes_iceberg` a partir de `clientes` (a tabela raw) com um `INSERT INTO ... SELECT`. Liste as colunas explicitamente — incluindo `ano_nascimento` — para deixar o contrato visível.

> 💡 **Apoio:** `INSERT INTO ... SELECT` em tabela Iceberg foi exercitado no [Lab 02.1 — Parte 5 (Inserindo dados)](../02-Open-Table-Format/01-Funcionalidades-Basicas/README.md#parte-5---inserindo-dados).

Valide o resultado:

```sql
SELECT COUNT(*) FROM trabalho_final_aluno.clientes_iceberg;
-- esperado: 10000
```

<a id="passo-9"></a>

**9.** Carregue `pedidos_iceberg` a partir de `pedidos` (a tabela raw). Aqui mora a **conversão de tipo crítica**: o crawler inferiu `data_pedido` como `STRING` (formato `YYYY-MM-DD`), mas a Iceberg está esperando `DATE`. Use:

```sql
... CAST(data_pedido AS DATE) AS data_pedido ...
```

no `SELECT`.

<details>
<summary><b>💡 Clique para entender: por que o CAST acontece na carga e não no Crawler</b></summary>
<blockquote>

Glue Crawler infere tipos a partir do conteúdo do CSV — e CSV é "tudo string". Mesmo que o conteúdo seja `2024-12-31`, o crawler classifica como `string`. Você poderia editar o schema da raw manualmente, mas perderia idempotência (re-rodar o crawler sobrescreve sua edição).

A prática canônica é: **deixar a raw como espelho fiel do CSV** (tudo `string` quando vem de CSV) e converter tipos **na CTAS / INSERT** para a tabela Iceberg. Esse é o padrão "schema-on-read" + "schema-on-write" do lakehouse.

A vantagem secundária: se amanhã o CSV vier com `data_pedido` em formato diferente (`DD/MM/YYYY`), você ajusta o `CAST` em UM lugar (a query de carga) sem reprocessar a raw.

</blockquote>
</details>

Valide o resultado:

```sql
SELECT
    COUNT(*)                  AS total,
    MIN(data_pedido)          AS data_min,
    MAX(data_pedido)          AS data_max,
    COUNT(DISTINCT id_cliente) AS clientes_distintos
FROM trabalho_final_aluno.pedidos_iceberg;
-- esperado: total=100000, data_min=2023-01-01, data_max=2024-12-31
```

> [!IMPORTANT]
> Se `data_min` ou `data_max` aparecer como `null` ou string, o `CAST` falhou em alguma linha (formato inesperado). Investigue com `SELECT data_pedido FROM pedidos WHERE data_pedido NOT LIKE '____-__-__' LIMIT 5;`.

### Checkpoint

- [ ] `clientes_iceberg` tem 10.000 linhas
- [ ] `pedidos_iceberg` tem 100.000 linhas
- [ ] `data_min = 2023-01-01` e `data_max = 2024-12-31`
- [ ] Snapshots criados — confirme com `SELECT * FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots"`

---

## Tarefa 5 - Adicionar coluna calculada `valor_final`

### Resultado esperado desta tarefa

Coluna `valor_final DOUBLE` adicionada em `pedidos_iceberg`, populada em todas as 100.000 linhas com a fórmula:

```
valor_final = quantidade * preco_unitario * (1 - desconto) + frete
```

---

<a id="passo-10"></a>

**10.** Use `ALTER TABLE ... ADD COLUMNS (valor_final DOUBLE)` para adicionar a coluna no schema. Esta operação é **barata em Iceberg** — só altera metadado, não reescreve arquivos de dados.

> 💡 **Apoio:** evolução de schema com `ALTER TABLE ADD COLUMNS` foi feita no [Lab 02.1](../02-Open-Table-Format/01-Funcionalidades-Basicas/README.md) (seção de evolução de schema, próximo dos passos 32-37).

<details>
<summary><b>💡 Clique para entender: ALTER TABLE em Iceberg é metadado</b></summary>
<blockquote>

Em Hive externa (data lake puro), adicionar coluna exige reescrever a tabela inteira (ou conviver com `null` em todas as linhas existentes para sempre, sem voltar atrás). Em Iceberg, o schema é versionado no metadado: o `ALTER` cria uma nova versão do schema, e linhas antigas continuam no Parquet original — quando lidas, são "preenchidas" com `null` na coluna nova até serem regravadas.

Por isso o `ALTER` roda em ~5 segundos. Já o `UPDATE` do passo 11 é o que demora — ele varre os 100k registros e regrava arquivos com a coluna materializada.

</blockquote>
</details>

<a id="passo-11"></a>

**11.** Rode um `UPDATE` que materializa `valor_final` em todas as linhas. Tempo esperado no Athena: **30–60 segundos**.

> 💡 **Apoio:** `UPDATE` materializando uma coluna calculada está no [Lab 03.3 (Tarefa 1 — comissão de fornecedores)](../03-Data-Modeling-e-Data-Warehouse/03-analise-dimensional/README.md), no padrão `UPDATE ... SET coluna = expressão`.

<a id="passo-12"></a>

**12.** Valide:

```sql
SELECT
    COUNT(*)                       AS total,
    COUNT(valor_final)             AS com_valor,
    ROUND(MIN(valor_final), 2)     AS min_valor,
    ROUND(MAX(valor_final), 2)     AS max_valor,
    ROUND(AVG(valor_final), 2)     AS media_valor
FROM trabalho_final_aluno.pedidos_iceberg;
-- esperado: total=100000, com_valor=100000 (zero NULLs)
-- min_valor > 0, max_valor < 15000 (ordem de grandeza)
```

### Checkpoint

- [ ] `valor_final` existe no schema (confirme com `DESCRIBE pedidos_iceberg`)
- [ ] `com_valor = total = 100000` (nenhum NULL)
- [ ] `min_valor > 0`

---

## Tarefa 6 - Aplicar delta de CDC com `MERGE INTO`

### Resultado esperado desta tarefa

A tabela `pedidos_iceberg` passa a ter **100.003 linhas** (3 inserts do delta + 100k - 0 deletes), e os 2 pedidos do delta com `operation = update` têm `desconto` e `valor_final` atualizados.

> [!IMPORTANT]
> Esta é a tarefa-âncora do trabalho. Marina te entregou 5 deltas (3 INSERTs + 2 UPDATEs) e quer ver o número final consolidado. Você vai aplicar os 5 em **um único MERGE transacional**.

### Estratégia

A fonte do `MERGE` precisa ter **a mesma estrutura da tabela alvo** — incluindo `valor_final` calculado. Como `pedidos_delta` (raw Hive externa, vinda do crawler) só tem as 8 colunas do CSV (sem `valor_final`), você precisa de uma **tabela intermediária Iceberg** que já materialize `valor_final` para cada delta.

```mermaid
flowchart LR
    Raw["pedidos_delta<br/>(raw, Hive externa, CSV)<br/>5 linhas, sem valor_final"]
    Inter["pedidos_delta_iceberg<br/>(Iceberg intermediária)<br/>5 linhas, COM valor_final"]
    Target["pedidos_iceberg<br/>(alvo final)<br/>100.000 linhas"]
    After["pedidos_iceberg<br/>após MERGE<br/>100.003 linhas (3 inserts + 2 updates)"]

    Raw -->|CTAS Iceberg<br/>com valor_final calculado| Inter
    Inter --->|MERGE INTO ON id_pedido| Target
    Target --> After

    style Raw fill:#fff5e6,stroke:#cc7a00
    style Inter fill:#e6f7ff,stroke:#0066cc
    style Target fill:#f0e6ff,stroke:#6600cc
    style After fill:#e6ffe6,stroke:#009933
```

---

<a id="passo-13"></a>

**13.** Crie a tabela intermediária `pedidos_delta_iceberg` via `CREATE TABLE ... AS SELECT` (CTAS) lendo de `pedidos_delta` (a tabela raw). Aplique no `SELECT`:

- `CAST(data_pedido AS DATE)` (mesmo motivo da Tarefa 4)
- `quantidade * preco_unitario * (1 - desconto) + frete AS valor_final`

LOCATION: `s3://tf-aluno-<ACCOUNT_ID>/iceberg/pedidos_delta/`

Propriedades do CTAS Iceberg (cláusula `WITH (...)`): `table_type='ICEBERG'`, `format='PARQUET'`, `write_compression='ZSTD'`, **`is_external=false`** (obrigatório para CTAS Iceberg — ver troubleshoot abaixo) e `location='s3://.../iceberg/pedidos_delta/'`.

<details>
<summary><b>⚠ Se der erro: <code>Only managed table is supported for Iceberg table type</code></b></summary>
<blockquote>

Causa: o Athena exige que tabelas Iceberg sejam **managed** (gerenciadas pelo próprio engine), não external. No CTAS isso é controlado pelo parâmetro `is_external`.

Solução: adicione `is_external = false` dentro do bloco `WITH (...)`, ao lado de `table_type='ICEBERG'`. Exemplo:

```sql
CREATE TABLE trabalho_final_aluno.pedidos_delta_iceberg
WITH (
    table_type        = 'ICEBERG',
    format            = 'PARQUET',
    write_compression = 'ZSTD',
    is_external       = false,
    location          = 's3://tf-aluno-<ACCOUNT_ID>/iceberg/pedidos_delta/'
) AS
SELECT ...
```

Sem `is_external = false`, o Athena tenta criar tabela Hive externa e o `table_type='ICEBERG'` é rejeitado. Esse parâmetro só aparece em CTAS — no `CREATE TABLE` "vazio" da Tarefa 3 a tabela já é managed por default quando se usa `TBLPROPERTIES`.

</blockquote>
</details>

Valide:

```sql
SELECT * FROM trabalho_final_aluno.pedidos_delta_iceberg ORDER BY id_pedido;
-- esperado: 5 linhas
-- 3 com id_pedido = O100001/O100002/O100003 (inserts novos)
-- 2 com id_pedido = O000001/O000002 (updates dos primeiros pedidos, desconto = 0.50 / 0.45)
```

<a id="passo-14"></a>

**14.** Aplique o `MERGE INTO`. Chave: `id_pedido`. Comportamento:

> 💡 **Apoio:** sintaxe completa de `MERGE INTO ... USING ... ON ... WHEN MATCHED THEN UPDATE / WHEN NOT MATCHED THEN INSERT` está no [Lab 02.2 — Funcionalidades Avançadas (Parte 2 — MERGE INTO)](../02-Open-Table-Format/02-Funcionalidades-avancadas/README.md#parte-2---atualizar-excluir-ou-inserir-linhas-condicionalmente-com-merge).

- `WHEN MATCHED` → `UPDATE SET` todas as colunas de negócio (incluindo `valor_final`)
- `WHEN NOT MATCHED` → `INSERT` com todas as colunas, incluindo `valor_final`

Tempo esperado: **10–30 segundos**.

<details>
<summary><b>💡 Clique para entender: por que CTAS Iceberg em vez de external table direta?</b></summary>
<blockquote>

Você poderia tentar fazer `MERGE INTO pedidos_iceberg USING pedidos_delta ...` direto (lendo a raw). Funcionaria *parcialmente* — mas teria 2 problemas:

1. **`valor_final` não está na raw.** Você teria que calcular dentro do `USING (SELECT ..., quantidade*preco_unitario*... AS valor_final FROM pedidos_delta)`, deixando a regra de negócio espalhada (ela já mora no UPDATE da Tarefa 5; agora moraria *também* no MERGE).
2. **`data_pedido` na raw é STRING.** Você teria que fazer `CAST` no `USING`, dobrando o número de lugares onde a conversão acontece.

A CTAS intermediária resolve os 2: regra de negócio fica num lugar só (a CTAS), e a fonte do MERGE tem schema idêntico à alvo. Bônus: a `pedidos_delta_iceberg` fica auditável — você pode revisitar exatamente o delta aplicado depois.

</blockquote>
</details>

<a id="passo-15"></a>

**15.** Valide o resultado:

```sql
-- 1) total deve ser 100.003 (100k + 3 inserts)
SELECT COUNT(*) FROM trabalho_final_aluno.pedidos_iceberg;

-- 2) os 2 updates devem ter desconto = 0.50 / 0.45
SELECT t.id_pedido, t.desconto, t.valor_final
FROM trabalho_final_aluno.pedidos_iceberg t
JOIN trabalho_final_aluno.pedidos_delta_iceberg s
  ON t.id_pedido = s.id_pedido
ORDER BY t.id_pedido;
-- esperado: 5 linhas, valor_final batendo com s.valor_final

-- 3) o snapshot do MERGE aparece com operation = overwrite
SELECT snapshot_id, operation, summary
FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

### Checkpoint

- [ ] `pedidos_iceberg` tem 100.003 linhas
- [ ] Os 2 ids_pedido do delta-update têm `desconto` atualizado e `valor_final` recalculado
- [ ] Snapshot novo com `operation = overwrite` aparece em `$snapshots`

---

## Tarefa 7 - Otimizar a tabela

### Resultado esperado desta tarefa

A tabela `pedidos_iceberg` é compactada (BIN_PACK) e o número de arquivos físicos cai significativamente. Snapshots históricos seguem consultáveis.

---

<a id="passo-16"></a>

**16.** Foto **antes** do OPTIMIZE — anote o número de arquivos:

```sql
SELECT COUNT(*) AS num_arquivos_antes
FROM "trabalho_final_aluno"."pedidos_iceberg$files";
```

<a id="passo-17"></a>

**17.** Rode o OPTIMIZE com estratégia BIN_PACK (default — agrupa arquivos pequenos em arquivos maiores até ~512 MB) e em seguida o VACUUM (limpa snapshots órfãos além do retention default):

> 💡 **Apoio:** `OPTIMIZE ... REWRITE DATA USING BIN_PACK` + inspeção de arquivos via `"tabela$files"` está no [Lab 02.2 — Parte 3 (Otimizando tabelas Iceberg)](../02-Open-Table-Format/02-Funcionalidades-avancadas/README.md#parte-3---otimizando-tabelas-iceberg).

```sql
OPTIMIZE trabalho_final_aluno.pedidos_iceberg REWRITE DATA USING BIN_PACK;
```

Em uma **query separada** (VACUUM não pode rodar em transação composta):

```sql
VACUUM trabalho_final_aluno.pedidos_iceberg;
```

<details>
<summary><b>⚠ Se der erro: <code>VACUUM cannot run inside a multiple commands statement</code></b></summary>
<blockquote>

Você executou `OPTIMIZE` e `VACUUM` no mesmo painel SQL (Athena considera isso um statement múltiplo). Quebre em 2 queries separadas. Mesmo padrão do Lab 02.2.

</blockquote>
</details>

<a id="passo-18"></a>

**18.** Foto **depois** do OPTIMIZE:

```sql
SELECT COUNT(*) AS num_arquivos_depois
FROM "trabalho_final_aluno"."pedidos_iceberg$files";

-- Snapshot novo com operation = replace
SELECT snapshot_id, operation, summary
FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
```

Espera-se: `num_arquivos_depois < num_arquivos_antes` (geralmente 1-3 arquivos), e um snapshot novo com `operation = replace`.

### Checkpoint

- [ ] Número de arquivos caiu (geralmente 1-3 arquivos depois)
- [ ] Snapshot com `operation = replace` aparece
- [ ] `SELECT COUNT(*)` continua retornando **100.003** (dados intactos)

---

## Tarefa 8 - Entrega da query executiva

### Resultado esperado desta tarefa

Uma query que devolve **5 linhas** com top 5 clientes por receita líquida total. Esse é o entregável simbólico para a Marina.

---

<a id="passo-19"></a>

**19.** Escreva a query: top 5 clientes por `SUM(valor_final)`, com `JOIN` entre `pedidos_iceberg` e `clientes_iceberg`. Colunas:

> 💡 **Apoio:** query analítica com `JOIN` entre fato e dimensão + `SUM` + `GROUP BY` + `ORDER BY ... DESC` é a query-âncora do [Lab 03.2 — Modelagem e Carga (passo 9, query da AUTOMOBILE em 1995)](../03-Data-Modeling-e-Data-Warehouse/02-modelagem-e-carga/README.md#passo-9).

| Coluna | Origem |
|--------|--------|
| id_cliente | clientes |
| nome_completo | `nome \|\| ' ' \|\| sobrenome` |
| cidade | clientes |
| estado | clientes |
| segmento | clientes |
| receita_total | `ROUND(SUM(valor_final), 2)` |
| qtd_pedidos | `COUNT(id_pedido)` |
| ticket_medio | `ROUND(AVG(valor_final), 2)` |

`ORDER BY receita_total DESC LIMIT 5`.

> [!TIP]
> Como a tabela `clientes_iceberg` agora tem `ano_nascimento`, você pode opcionalmente enriquecer a query com a idade dos clientes do top 5 (ex: `2024 - ano_nascimento AS idade`) — útil para a Marina entender o perfil dos top compradores. Não é obrigatório, mas conta ponto de maturidade analítica.

<a id="passo-20"></a>

**20.** Anote o `id_cliente` do **#1 da lista** e a `receita_total`.

### Checkpoint

- [ ] Query retorna 5 linhas
- [ ] `receita_total` está em ordem decrescente
- [ ] Cada linha tem `qtd_pedidos > 0` e `ticket_medio > 0`

---

## Tarefa 9 - Escrever `DECISION.md`

### Resultado esperado desta tarefa

Um arquivo `DECISION.md` (estilo ADR — Architecture Decision Record) defendendo **uma** decisão técnica de evolução do lakehouse caso a TPCH cresça 100× (de 100k para 10M pedidos).

---

<a id="passo-21"></a>

**21.** Crie um arquivo `DECISION.md` na sua pasta de entregáveis do Codespaces, com a estrutura:

> 💡 **Apoio:** o padrão de "recado para o stakeholder" + decisão técnica defendida foi feito no [Lab 03.2 (passo final — recado para Marina)](../03-Data-Modeling-e-Data-Warehouse/02-modelagem-e-carga/README.md). Use a mesma estrutura: contexto, decisão, alternativas descartadas, consequências.

```markdown
# DECISION — Como evoluir `pedidos_iceberg` se a TPCH crescer 100×

## Contexto
<2-3 linhas: situação atual + cenário futuro>

## O que eu mudaria primeiro
<a decisão principal: particionamento? Z-ordering? materialized view? streaming? Qual e por quê. Dê 2-3 razões objetivas.>

## Alternativas que descartei (nesta primeira iteração)
<tabela com 3-4 alternativas e por que NÃO agora>

## Como eu validaria a decisão
<2-3 queries ou métricas que você rodaria para confirmar que a escolha foi a certa>

## Pergunta para validar com o stakeholder
<1 pergunta para a Marina que ajudaria a decidir>
```

> [!IMPORTANT]
> Não tem "resposta correta única". O gabarito (que o professor usa para referência) defende particionamento por mês. Você pode defender Z-ordering, materialized view ou streaming — desde que o raciocínio seja consistente, com trade-offs explícitos. **Critério: capacidade de defender a escolha em 5 minutos numa entrevista técnica sênior.**

### Checkpoint

- [ ] `DECISION.md` existe com as 5 seções
- [ ] A decisão principal tem 2-3 razões objetivas
- [ ] Pelo menos 3 alternativas foram explicitamente descartadas
- [ ] Pergunta para o stakeholder está formulada

---

## Tarefa 10 - Empacotar e enviar no portal FIAP

### Resultado esperado desta tarefa

Um arquivo `.zip` com **estrutura exata** abaixo, que você sobe no **portal FIAP** no espaço do trabalho que o professor criou para a sua turma.

> [!IMPORTANT]
> O **formato de entrega importa**. O professor corrige dezenas de trabalhos por turma — uma estrutura inconsistente atrasa a correção e pode custar pontos. Siga a estrutura abaixo **literalmente**.

### Estrutura obrigatória do zip

```
trabalho-final.zip
└── trabalho-final/
    ├── sql/
    │   ├── 01_create_iceberg_tables.sql
    │   ├── 02_insert_data.sql
    │   ├── 03_add_calculated_column.sql
    │   ├── 04_merge_delta.sql
    │   ├── 05_optimize.sql
    │   └── 06_query_executiva.sql
    ├── prints/
    │   ├── 01_show_create_iceberg.png          (Tarefa 3: SHOW CREATE TABLE pedidos_iceberg com TBLPROPERTIES Iceberg)
    │   ├── 02_count_apos_merge.png             (Tarefa 6: SELECT COUNT(*) FROM pedidos_iceberg = 100003)
    │   └── 03_top5_clientes.png                (Tarefa 8: resultado das 5 linhas da query executiva)
    └── DECISION.md
```

**Detalhes:**

- Cada `.sql` é o **arquivo que vocês efetivamente rodaram no Athena** — não a versão do gabarito, não o rascunho. Limpo, comentado, com `<ACCOUNT_ID>` substituído pelo valor real.
- Cada `.png` é um screenshot **legível** (sem zoom de microscópio nem janela cortada). Se não couber tudo, prefiram 2 screenshots (`04a_...png`, `04b_...png`).
- `DECISION.md` é o que vocês escreveram na Tarefa 9.

---

<a id="passo-22"></a>

**22.** Na **máquina local de um do grupo** (Windows, Mac ou Linux), crie uma pasta `trabalho-final/` com os 10 arquivos exatamente como na estrutura acima — use o gerenciador de arquivos do SO. Não há comando padrão entre os 3 sistemas, então faça pelo Explorer / Finder / Nautilus mesmo.

<details>
<summary><b>⚠ Se faltar arquivo: revise as Tarefas 2-9</b></summary>
<blockquote>

| Arquivo faltando | Volte para |
|---|---|
| `01_create_iceberg_tables.sql` | Tarefa 3 (passos 6 e 7) |
| `02_insert_data.sql` | Tarefa 4 (passos 8 e 9) |
| `03_add_calculated_column.sql` | Tarefa 5 (passos 10 e 11) |
| `04_merge_delta.sql` | Tarefa 6 (passos 13 e 14) |
| `05_optimize.sql` | Tarefa 7 (passo 17) |
| `06_query_executiva.sql` | Tarefa 8 (passo 19) |
| `01_show_create_iceberg.png` | Tarefa 3 (depois do passo 7 — `SHOW CREATE TABLE pedidos_iceberg`) |
| `02_count_apos_merge.png` | Tarefa 6 (depois do passo 15 — `COUNT(*) = 100003`) |
| `03_top5_clientes.png` | Tarefa 8 (depois do passo 19) |
| `DECISION.md` | Tarefa 9 (passo 21) |

</blockquote>
</details>

---

<a id="passo-23"></a>

**23.** Compacte a pasta `trabalho-final/` em um zip e suba no **portal FIAP**, no espaço do trabalho que o professor criou para a sua turma.

| SO | Como zipar |
|----|------------|
| Windows | Botão direito na pasta → **Enviar para → Pasta compactada (zip)** |
| Mac | Botão direito na pasta → **Comprimir "trabalho-final"** |
| Linux | Botão direito na pasta → **Comprimir → .zip** |

> [!CAUTION]
> O upload no portal é **a única forma de submissão válida**. Repositório próprio, e-mail, Slack: nada disso conta como entrega.

---

## Tarefa 11 - Limpeza

### Resultado esperado desta tarefa

Bucket S3 vazio e tabelas Glue removidas. Conta AWS limpa, Learner Lab budget preservado.

---

<a id="passo-24"></a>

**24.** Limpe os recursos. **Esta etapa é obrigatória** — esquecer de limpar consome budget do Learner Lab.

```bash
# Esvazia o bucket (necessario antes de deletar)
aws s3 rm "s3://tf-aluno-$(aws sts get-caller-identity --query Account --output text)" --recursive

# Apaga o bucket
aws s3 rb "s3://tf-aluno-$(aws sts get-caller-identity --query Account --output text)"
```

E no console Glue:

1. **Databases** → `trabalho_final_aluno` → **Action → Delete database** (apaga tabelas e database juntos).
2. **Crawlers** → `crawler-trabalho-final-aluno` → **Action → Delete**.

> [!CAUTION]
> Confirme que o bucket sumiu com `aws s3 ls | grep tf-aluno`. Se ainda aparecer, repita o `rb`. Bucket vazio também cobra (storage de logs e metadados de versionamento), então **delete tudo**, não só esvazie.

---

## Conclusão

Se você chegou até aqui, então entregou:

- **Pipeline lakehouse ponta a ponta** (CSV → Glue Catalog → Iceberg → MERGE → OPTIMIZE)
- **Tabela auditável** com 100.003 pedidos e 5 snapshots (insert clientes, insert pedidos, alter+update valor_final, merge delta, optimize replace)
- **Query executiva** para a Marina (top 5 clientes)
- **`DECISION.md`** defendendo evolução técnica em ADR

**Mensagem para a Marina**: o pipeline está pronto, o número fechou, e dá para repetir o ciclo (delta diário) sem reescrever a tabela. Os ajustes do CDC viraram um único `MERGE`, e a manutenção mensal é um `OPTIMIZE` agendado. **TPCH Trading agora opera como lakehouse.**

---

<details>
<summary><b>💡 Glossário rápido — termos que aparecem neste trabalho</b></summary>
<blockquote>

| Termo | O que é |
|-------|---------|
| **Glue Crawler** | Serviço AWS que varre um prefixo S3, infere schema dos arquivos (CSV/Parquet) e cria tabelas no Glue Data Catalog. Padrão "schema-on-read". |
| **Tabela raw / external** | Tabela Hive externa que aponta para arquivos no S3. Sem `UPDATE`/`DELETE`/snapshots. Usada como espelho fiel do dado bruto. |
| **Iceberg** | Formato aberto de tabela com camada de metadados transacional (snapshots, manifests, deletes). Suporta `INSERT`, `UPDATE`, `DELETE`, time travel, evolução de esquema. |
| **CTAS** | `CREATE TABLE ... AS SELECT`. Cria a tabela e popula em um único comando. Padrão para tabela intermediária Iceberg. |
| **`MERGE INTO`** | Comando que combina `INSERT` + `UPDATE` (+ `DELETE`) em uma única instrução transacional. Padrão de aplicação de CDC. |
| **CDC (Change Data Capture)** | Padrão onde uma fonte gera registros marcados como insert/update/delete; o consumidor aplica via `MERGE`. |
| **OPTIMIZE BIN_PACK** | Estratégia que agrupa arquivos pequenos em arquivos maiores (~512 MB) sem alterar conteúdo. Mantém saúde da tabela ao longo do tempo. |
| **VACUUM** | Remove snapshots e arquivos órfãos além do retention configurado (default: 5 dias). Roda **fora de transação composta**. |
| **`$snapshots`** | Tabela virtual `<tabela>$snapshots` exposta pelo Iceberg para inspecionar histórico de operações. |
| **`$files`** | Tabela virtual com a lista de arquivos físicos da tabela Iceberg — útil para medir efeito do `OPTIMIZE`. |

</blockquote>
</details>

<details>
<summary><b>💡 Como pedir ajuda se travou</b></summary>
<blockquote>

Antes de abrir issue/perguntar no Slack, colete estas 4 informações:

1. **Em que passo você está** (ex: "passo 14, rodando o `MERGE INTO`")
2. **Mensagem de erro literal** (copia-cola completo do painel de query do Athena)
3. **Saída de** `SELECT operation, count(*) FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots" GROUP BY operation;` (mostra histórico de operações)
4. **O que você já tentou**

Canais (em ordem de prioridade):

- **Issues do repositório**: [github.com/vamperst/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/issues](https://github.com/vamperst/FIAP-Data-Warehouse-Lakehouse-e-Data-Mesh/issues)
- **E-mail do professor**: `rafael.barbosa@fiap.com.br`

</blockquote>
</details>
