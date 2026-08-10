# ADR-001: Particionamento mensal de `pedidos_iceberg` para suporte a 100× o volume atual

- **Status:** Aceita
- **Data:** 2026-08-06
- **Decisores:** Grupo do trabalho
- **Escopo:** Evolução arquitetural da camada analítica de pedidos

---

## Contexto

O pipeline atual processa **100.000 pedidos** e **10.000 clientes** armazenados no Amazon S3,
consultados via Amazon Athena com tabelas no formato Apache Iceberg. A solução funciona
adequadamente nesse volume, mas o negócio projeta crescimento para **10.000.000 de pedidos**
(100× o volume atual) ao longo de 3 anos de operação.

Nesse cenário, toda consulta analítica que não se beneficia de pruning de partição passa a
realizar varredura completa da tabela (`pedidos_iceberg`), o que aumenta:

- o tempo de resposta das queries;
- o custo por consulta no Athena (cobrado por TB varrido);
- o volume de dados lidos nas operações de `MERGE` e `OPTIMIZE`.

A questão arquitetural a decidir é: **qual estratégia de particionamento adotar em
`pedidos_iceberg` para que o sistema continue eficiente com 10 milhões de registros?**

---

## Decisão

Adotar **particionamento oculto (hidden partitioning) por mês** na coluna `data_pedido`
da tabela `pedidos_iceberg`, utilizando a função de transformação `months(data_pedido)`
disponível no Apache Iceberg.

```sql
CREATE TABLE pedidos_iceberg (
    pedido_id    BIGINT,
    cliente_id   BIGINT,
    data_pedido  DATE,
    status       VARCHAR(20),
    valor        DECIMAL(10,2),
    valor_final  DECIMAL(10,2)
)
LOCATION 's3://bucket/pedidos_iceberg/'
TBLPROPERTIES (
    'table_type'      = 'ICEBERG',
    'write_compression' = 'snappy',
    'partitioning'    = 'months(data_pedido)'
);
```

O particionamento por mês é oculto: a coluna `data_pedido` permanece visível normalmente
nas queries sem necessidade de coluna de partição separada. O Athena injeta o filtro de
pruning automaticamente quando a cláusula `WHERE` restringe `data_pedido`.

---

## Alternativas consideradas e descartadas

### 1. Sem particionamento (situação atual)

A tabela sem particionamento funciona bem com 100.000 registros. A 100×, toda consulta
que filtra por período realiza varredura completa de ~1,5 GB de Parquet comprimido.

| Métrica              | 100k linhas | 10M linhas (100×) |
|----------------------|-------------|-------------------|
| Tamanho estimado     | ~15 MB      | ~1,5 GB           |
| Scan por query       | 15 MB       | 1,5 GB (total)    |
| Custo Athena / query | ~$0,000075  | ~$0,0075          |
| Custo diário (1k q.) | ~$0,075     | **~$7,50**        |

**Descartada** porque o custo e o tempo de resposta crescem linearmente com o volume sem
nenhum mecanismo de pruning.

---

### 2. Particionamento por dia (`days(data_pedido)`)

Com 3 anos de dados e carga diária, seriam geradas ~1.095 partições. Com 10M de pedidos
distribuídos uniformemente, cada partição teria ~9.100 registros e ~1,4 MB — muito abaixo
do tamanho mínimo recomendado de 128 MB para arquivos Parquet eficientes.

Consequências:
- Milhares de arquivos pequenos no S3 (small file problem);
- `OPTIMIZE` precisaria de execuções frequentes e custosas para compactar as partições;
- O overhead do planejador de queries aumenta com o número de manifestos Iceberg.

**Descartada** por gerar granularidade excessiva e fragmentação de arquivos.

---

### 3. Particionamento por `cliente_id` (hash ou bucket)

A cardinalidade de `cliente_id` cresce junto com o volume (1M de clientes a 100×).
As queries analíticas típicas — como top 5 clientes por receita — acessam múltiplos
clientes simultaneamente, exigindo leitura de muitas partições de uma só vez.

Além disso, o número de arquivos por partição seria ínfimo (~10 pedidos/cliente em média),
resultando no mesmo problema de small files da alternativa anterior.

**Descartada** porque o padrão de acesso não se beneficia de pruning por cliente_id
em queries de agregação.

---

### 4. Particionamento por `status` (baixa cardinalidade)

O campo `status` possui poucos valores distintos (ex.: `PENDENTE`, `PAGO`, `CANCELADO`).
Uma partição por status agruparia milhões de registros sem reduzir o volume varrido
nas queries mais comuns, que filtram por intervalo de datas.

**Descartada** porque não reduz o custo de scan nas queries analíticas predominantes.

---

## Justificativa da decisão

O particionamento mensal equilibra três fatores:

**Granularidade adequada:** com 3 anos de histórico, são geradas ~36 partições. Cada
partição contém ~278.000 registros e ocupa ~43 MB comprimido — dentro da faixa ideal
de 128 MB a 512 MB após `OPTIMIZE REWRITE DATA USING BIN_PACK`.

**Pruning eficiente para o padrão de acesso real:** queries de fechamento mensal,
relatórios trimestrais e análises de tendência filtram naturalmente por intervalos de
datas, eliminando automaticamente as partições fora do intervalo.

**Compatibilidade com `MERGE` incremental:** os deltas de CDC chegam com `data_pedido`
recente. O Iceberg reescreve apenas os arquivos da partição afetada, não a tabela inteira.

---

## Métricas de validação

A decisão será considerada válida quando, com 10M de registros, os seguintes critérios
forem atendidos:

| Métrica                                    | Meta                              |
|--------------------------------------------|-----------------------------------|
| Tamanho de arquivo por partição (pós-OPTIMIZE) | 128 MB – 512 MB               |
| Número de partições                        | ≤ 60 (5 anos de dados)            |
| Redução de scan em query com filtro 3 meses | ≥ 90% vs. varredura total        |
| Custo Athena por query com filtro de 1 mês | ≤ $0,001                          |
| Tempo de execução de `MERGE` diário        | ≤ 2× o tempo atual (com 100k)     |

### Projeção de custo comparada

Considerando 10M de pedidos (~1,5 GB Parquet comprimido), Athena a $5/TB e
1.000 queries/dia com filtro de 3 meses:

|                         | Sem partição | Com partição mensal |
|-------------------------|-------------|---------------------|
| Dados varridos/query    | 1,5 GB      | ~125 MB (8,3%)      |
| Custo/query             | $0,0075     | $0,00063            |
| Custo diário (1k q.)    | $7,50       | $0,63               |
| **Economia mensal**     | —           | **~$206/mês**       |

---

## Consequências

**Positivas:**
- Redução de ~92% no volume varrido por queries com filtro temporal.
- `MERGE` reescreve apenas arquivos da partição do delta, reduzindo custo e tempo.
- O crescimento de novas partições é previsível e controlado (1 partição/mês).
- Nenhuma alteração na interface SQL: as queries existentes continuam funcionando sem modificação.

**Negativas e cuidados:**
- A criação da tabela precisa incluir a cláusula `partitioning` desde o início;
  adicionar particionamento a uma tabela Iceberg existente exige recriação com CTAS.
- Queries sem filtro em `data_pedido` continuam varrendo todas as partições.
- O `OPTIMIZE` deve ser executado por partição (com filtro de data) para evitar
  reescrever toda a tabela de uma vez.
- O `VACUUM` deve respeitar um período mínimo de retenção compatível com a janela
  de auditoria exigida pelo negócio.

---

## Conclusão

A adoção de particionamento oculto por mês em `pedidos_iceberg` é a estratégia que
melhor equilibra custo operacional, performance de query e simplicidade de manutenção
no horizonte de 100× o volume atual. As alternativas avaliadas ou não reduzem o custo
de scan, ou geram fragmentação de arquivos incompatível com o Athena em produção.
