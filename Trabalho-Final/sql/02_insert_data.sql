-- Tarefa 4 - Carregar dados iniciais

-- clientes

INSERT INTO trabalho_final_aluno.clientes_iceberg (
  id_cliente,
  nome,
  sobrenome,
  ano_nascimento,
  cidade,
  estado,
  segmento
)
SELECT
  id_cliente,
  nome,
  sobrenome,
  ano_nascimento,
  cidade,
  estado,
  segmento
FROM trabalho_final_aluno.clientes;

-- validando carga de clientes
SELECT COUNT(*) FROM trabalho_final_aluno.clientes_iceberg;
-- esperado: 10000

-- pedidos

INSERT INTO trabalho_final_aluno.pedidos_iceberg (
  id_pedido,
  id_cliente,
  data_pedido,
  categoria_produto,
  quantidade,
  preco_unitario,
  desconto,
  frete
)
SELECT
  id_pedido,
  id_cliente,
  CAST(data_pedido AS DATE) AS data_pedido,
  categoria_produto,
  quantidade,
  preco_unitario,
  desconto,
  frete
FROM trabalho_final_aluno.pedidos;

-- validando carga de pedidos
SELECT
    COUNT(*)                   AS total,
    MIN(data_pedido)           AS data_min,
    MAX(data_pedido)           AS data_max,
    COUNT(DISTINCT id_cliente) AS clientes_distintos
FROM trabalho_final_aluno.pedidos_iceberg;
-- esperado: 
--   total = 100000
--   data_min=2023-01-01
--   data_max=2024-12-31

-- validando snapshots gerados pela carga (1 por INSERT)
SELECT * FROM "trabalho_final_aluno"."clientes_iceberg$snapshots";
SELECT * FROM "trabalho_final_aluno"."pedidos_iceberg$snapshots";
