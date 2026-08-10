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

A questão a decidir é: **qual estratégia de particionamento adotar em
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

O particionamento por mês é oculto, ou seja, a coluna `data_pedido` permanece visível normalmente
nas queries sem necessidade de coluna de partição separada. O Athena adiciona o filtro de
expurgo (pruning) automaticamente quando a cláusula `WHERE` restringe o campo`data_pedido`.

---

## Alternativas consideradas e descartadas

### 1. Sem particionamento (AS IS)

A tabela sem particionamento funciona bem com poucos registros (100k no nosso cenário).

Se fosse 100x, toda consulta que filtra por período realiza varredura completa de ~1,5 GB nos Parquets comprimidos. Isso elevaria o custo do athena diário de uma fração de centavos para algo na casa dos 7,50 dólares.

Essa alternativa foi **descartada** porque o custo e o tempo de resposta crescem linearmente com o volume sem nenhum mecanismo de expurgo.

---

### 2. Particionamento por dia (`days(data_pedido)`)

Com 3 anos de dados e carga diária, seriam geradas ~1.095 partições. Com 10 milhões de pedidos, cada partição teria ~9.100 registros e ~1,4 MB, o que é muito abaixo do tamanho mínimo recomendado de 128 MB para arquivos Parquet eficientes.

Consequências:

- Milhares de arquivos pequenos no S3 (small files);
- O`OPTIMIZE` precisaria de execuções frequentes e custosas para compactar as partições;
- O overhead do planejador de queries aumentaria com o número de manifestos Iceberg.

Essa alternativa também foi **descartada** por gerar granularidade excessiva e fragmentação de arquivos.

---

### 3. Particionamento por `cliente_id` (hash ou bucket)

A cardinalidade de `cliente_id` cresce junto com o volume. As queries analíticas típicas, como por exemplo os top 5 clientes por receita, acessam múltiplos clientes simultaneamente, exigindo leitura de muitas partições de uma só vez.

Além disso, o número de arquivos por partição seria muito pequeno, na casa de 10 pedidos por cliente em média, resultando no mesmo problema de small files da alternativa anterior.

**Descartamos** essa opção porque o pruning não faria diferença por cliente_id em queries de agregação.

---

### 4. Particionamento por `status`

O campo `status` possui poucos valores distintos (ex.: `PENDENTE`, `PAGO`, `CANCELADO`).
Uma partição por status agruparia milhões de registros sem reduzir o volume varrido
nas queries mais comuns, que filtram por intervalo de datas.

**Descartamos também** porque não reduz o custo de scan nas queries analíticas predominantes.

---

## Justificativa da decisão

O particionamento mensal equilibra três fatores:

**Granularidade adequada:** com 3 anos de histórico, são geradas ~36 partições. Cada
partição contém ~278.000 registros e ocupa ~43 MB comprimido, o que consideramos dentro da faixa ideal de 128 MB a 512 MB após o comando`OPTIMIZE REWRITE DATA USING BIN_PACK`.

**Pruning eficiente para o padrão de acesso real:** queries de fechamento mensal,
relatórios trimestrais e análises de tendência filtram naturalmente por intervalos de
datas, eliminando automaticamente as partições fora do intervalo.

**Compatibilidade com `MERGE` incremental:** os deltas de CDC chegam com o`data_pedido` mais  recente. O Iceberg reescreve apenas os arquivos da partição afetada, sem a necessidade de reescrever a tabela inteira.

---

## Consequências

**Positivas:**

- Redução de ~92% no volume varrido por queries com filtro temporal.
- `MERGE` reescreve apenas arquivos da partição do delta, reduzindo custo e tempo.
- O crescimento de novas partições é previsível e controlado (1 partição/mês).
- Nenhuma alteração na interface SQL: as queries existentes continuam funcionando sem modificação.

**Negativas:**

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
melhor equilibra custos, performance e simplicidade de manutenção pensando em registros na casa de 100x o volume atual. As alternativas avaliadas ou não reduzem o custo de scan, ou geram fragmentação de arquivos, o que seria prejudicial para o projeto.
