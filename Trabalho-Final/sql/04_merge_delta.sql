-- Tarefa 6 - Aplicar delta de CDC com MERGE INTO


-- passo 1: criar tabela intermediaria pedidos_delta_iceberg via CTAS
-- lendo da tabela raw pedidos_delta (criada pelo Glue Crawler)
-- ja aplica CAST de data_pedido e calcula valor_final

CREATE TABLE trabalho_final_aluno.pedidos_delta_iceberg
WITH (
    table_type        = 'ICEBERG',
    format            = 'PARQUET',
    write_compression = 'ZSTD',
    is_external       = false,
    location          = 's3://tf-aluno-401154849741/iceberg/pedidos_delta/'
) AS
SELECT
    id_pedido,
    id_cliente,
    CAST(data_pedido AS DATE)                                          AS data_pedido,
    categoria_produto,
    quantidade,
    preco_unitario,
    desconto,
    frete,
    quantidade * preco_unitario * (1 - desconto) + frete               AS valor_final
FROM trabalho_final_aluno.pedidos_delta;


-- validando a tabela intermediaria
-- esperado: 5 linhas
--   3 com id_pedido O100001/O100002/O100003 (inserts novos)
--   2 com id_pedido O000001/O000002 (updates de pedidos existentes)
SELECT * FROM trabalho_final_aluno.pedidos_delta_iceberg ORDER BY id_pedido;


-- passo 2: aplicar o MERGE INTO na tabela principal
-- chave de uniao: id_pedido
-- WHEN MATCHED     -> atualiza todas as colunas de negocio (2 pedidos existentes com desconto corrigido)
-- WHEN NOT MATCHED -> insere como novo pedido (3 pedidos novos)
-- tempo esperado: 10-30 segundos

MERGE INTO trabalho_final_aluno.pedidos_iceberg t
USING trabalho_final_aluno.pedidos_delta_iceberg s
ON t.id_pedido = s.id_pedido
WHEN MATCHED THEN
    UPDATE SET
        id_cliente        = s.id_cliente,
        data_pedido       = s.data_pedido,
        categoria_produto = s.categoria_produto,
        quantidade        = s.quantidade,
        preco_unitario    = s.preco_unitario,
        desconto          = s.desconto,
        frete             = s.frete,
        valor_final       = s.valor_final
WHEN NOT MATCHED THEN
    INSERT (
        id_pedido,
        id_cliente,
        data_pedido,
        categoria_produto,
        quantidade,
        preco_unitario,
        desconto,
        frete,
        valor_final
    )
    VALUES (
        s.id_pedido,
        s.id_cliente,
        s.data_pedido,
        s.categoria_produto,
        s.quantidade,
        s.preco_unitario,
        s.desconto,
        s.frete,
        s.valor_final
    );


-- validando resultado final
-- esperado: 100003 linhas (100000 originais + 3 inserts do delta)
SELECT COUNT(*) AS total_pedidos
FROM trabalho_final_aluno.pedidos_iceberg;


-- validando que os 2 updates foram aplicados corretamente
SELECT t.id_pedido, t.desconto, t.valor_final
FROM trabalho_final_aluno.pedidos_iceberg t
JOIN trabalho_final_aluno.pedidos_delta_iceberg s
  ON t.id_pedido = s.id_pedido
ORDER BY t.id_pedido;
-- esperado: 5 linhas, valor_final de cada linha batendo com d.valor_final


-- validando snapshot gerado pelo MERGE
SELECT snapshot_id, operation, summary
FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
-- esperado: snapshot novo com operation = overwrite
