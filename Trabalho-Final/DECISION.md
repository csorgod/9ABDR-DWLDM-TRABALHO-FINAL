# ADR-001: Uso de tabelas Apache Iceberg para armazenamento analítico

- **Status:** Aceita
- **Data:** 2026-08-06
- **Decisores:** Grupo do trabalho
- **Escopo:** Camada analítica de clientes e pedidos

## Contexto

O projeto recebe dados de clientes e pedidos em arquivos armazenados no Amazon S3. 
Além da carga inicial, existe um conjunto de alterações incrementais na tabela 
`pedidos_delta`, contendo registros novos e alterações de pedidos existentes.

A solução precisava atender aos seguintes requisitos:

- armazenar os dados de forma analítica;
- permitir consultas SQL pelo Amazon Athena;
- realizar atualizações e inserções incrementais;
- manter a consistência dos dados durante o processamento de CDC;
- possibilitar otimização e manutenção das tabelas;
- evitar a necessidade de reprocessar toda a tabela a cada alteração.

## Decisão

O grupo decidiu utilizar tabelas **Apache Iceberg** consultadas pelo **Amazon Athena**.

Foram criadas as tabelas:

- `clientes_iceberg`;
- `pedidos_iceberg`.

A carga inicial foi realizada a partir das tabelas catalogadas pelo AWS Glue. 
Para o processamento incremental dos pedidos, foi utilizado o comando `MERGE`, 
permitindo atualizar pedidos existentes e inserir novos pedidos na mesma operação.

A tabela `pedidos_iceberg` foi atualizada com os registros da tabela 
`pedidos_delta`.

## Implementação realizada

A solução foi executada nas seguintes etapas:

1. Catalogação dos arquivos de origem por meio do AWS Glue Crawler.
2. Criação das tabelas Iceberg no banco `trabalho_final_aluno`.
3. Carga inicial de 10.000 clientes.
4. Carga inicial de 100.000 pedidos.
5. Execução do `MERGE` para processamento dos 5 registros de CDC.
6. Atualização de 2 pedidos existentes.
7. Inserção de 3 novos pedidos.
8. Execução de `OPTIMIZE` com `REWRITE DATA USING BIN_PACK`.
9. Execução de `VACUUM` para manutenção das tabelas.

## Evidências da execução

Após o processamento do CDC, foram obtidos os seguintes resultados:

- Total inicial de pedidos: **100.000**;
- Registros de CDC processados: **5**;
- Pedidos atualizados: **2**;
- Novos pedidos inseridos: **3**;
- Total final de pedidos: **100.003**;
- Total de clientes: **10.000**.

A consulta executiva também foi executada para identificar os cinco clientes 
com maior valor total gasto.

## Alternativas consideradas

### Arquivos Parquet sem formato de tabela

O uso direto de arquivos Parquet seria simples e adequado para cargas somente de 
leitura. Entretanto, essa alternativa não oferece, de forma nativa, a mesma 
facilidade para realizar atualizações e exclusões transacionais em registros 
individuais.

### Tabela Hive tradicional

Uma tabela Hive poderia ser utilizada para consultas no Athena, mas exigiria 
maior complexidade para controlar alterações, arquivos e consistência durante 
processamentos incrementais.

### Apache Iceberg

O Iceberg foi escolhido por oferecer:

- suporte a operações de `INSERT`, `UPDATE`, `DELETE` e `MERGE`;
- evolução de esquema;
- controle de snapshots;
- maior consistência para cargas incrementais;
- integração com o Amazon Athena;
- possibilidade de otimização e limpeza por meio de `OPTIMIZE` e `VACUUM`.

## Consequências positivas

- O CDC pode ser processado sem recarregar todos os pedidos.
- A operação `MERGE` trata atualizações e inserções em uma única consulta.
- As tabelas podem ser consultadas diretamente com SQL no Athena.
- A manutenção dos arquivos pode ser realizada com `OPTIMIZE` e `VACUUM`.
- O histórico baseado em snapshots oferece maior controle sobre as alterações.

## Consequências negativas e cuidados

- As tabelas exigem rotinas periódicas de manutenção.
- O uso incorreto de `VACUUM` pode remover snapshots necessários para consultas 
  ou auditorias.
- É necessário controlar corretamente a chave de correspondência utilizada no 
  `MERGE`.
- Consultas e operações de manutenção podem gerar custos no Amazon Athena.
- O formato exige conhecimento específico sobre tabelas Iceberg e seus comandos 
  de manutenção.

## Resultado

A decisão foi considerada adequada para o escopo do trabalho. A solução permitiu 
realizar a carga inicial, processar corretamente o CDC e finalizar com 
**100.003 pedidos** e **10.000 clientes**, mantendo as tabelas disponíveis para 
consultas analíticas no Amazon Athena.

## Conclusão

O grupo adotou o Apache Iceberg como formato de tabela para equilibrar 
flexibilidade analítica, suporte a atualizações incrementais e integração com os 
serviços AWS utilizados no projeto.