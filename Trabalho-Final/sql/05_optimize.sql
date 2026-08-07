-- Otimização da tabela pedidos_iceberg
OPTIMIZE trabalho_final_aluno.pedidos_iceberg REWRITE DATA USING BIN_PACK;

-- Limpeza de snapshots antigos de pedidos_iceberg
VACUUM trabalho_final_aluno.pedidos_iceberg;

-- Otimização da tabela clientes_iceberg
OPTIMIZE trabalho_final_aluno.clientes_iceberg REWRITE DATA USING BIN_PACK;

-- Limpeza de snapshots antigos de clientes_iceberg
VACUUM trabalho_final_aluno.clientes_iceberg;