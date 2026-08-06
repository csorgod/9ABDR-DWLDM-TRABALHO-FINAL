-- Tarefa 5 - Adicionar coluna calculada valor_final


-- passo 1: adicionar a coluna valor_final no schema
-- operacao barata em Iceberg: so altera metadado, nao reescreve arquivos

ALTER TABLE trabalho_final_aluno.pedidos_iceberg
ADD COLUMNS (valor_final DOUBLE);


-- validando que a coluna foi criada (deve aparecer valor_final double no final)
DESCRIBE trabalho_final_aluno.pedidos_iceberg;


-- passo 2: popular valor_final em todos os 100.000 pedidos
-- formula: quantidade * preco_unitario * (1 - desconto) + frete
-- tempo esperado: 30-60 segundos

UPDATE trabalho_final_aluno.pedidos_iceberg
SET valor_final = quantidade * preco_unitario * (1 - desconto) + frete;


-- validando o resultado apos o UPDATE
SELECT
    COUNT(*)                       AS total,
    COUNT(valor_final)             AS com_valor,
    ROUND(MIN(valor_final), 2)     AS min_valor,
    ROUND(MAX(valor_final), 2)     AS max_valor,
    ROUND(AVG(valor_final), 2)     AS media_valor
FROM trabalho_final_aluno.pedidos_iceberg;
-- esperado:
--   total    = 100000
--   com_valor = 100000 (zero NULLs)
--   min_valor > 0
--   max_valor < 15000


-- validando snapshots gerados pelo UPDATE
SELECT snapshot_id, operation, summary
FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots"
ORDER BY committed_at DESC
LIMIT 5;
