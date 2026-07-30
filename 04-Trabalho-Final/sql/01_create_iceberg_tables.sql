-- clientes

CREATE TABLE trabalho_final_aluno.clientes_iceberg (
  id_cliente string,
  nome string,
  sobrenome string,
  ano_nascimento int,
  cidade string,
  estado string,
  segmento string
)
LOCATION 's3://tf-aluno-401154849741/iceberg/clientes/'
TBLPROPERTIES (
  'table_type'='iceberg',
  'format'='parquet',
  'write_compression'='zstd'
);


-- pedidos

CREATE TABLE trabalho_final_aluno.pedidos_iceberg (
  id_pedido string,
  id_cliente string,
  data_pedido date,
  categoria_produto string,
  quantidade int,
  preco_unitario double,
  desconto double,
  frete double
)
LOCATION 's3://tf-aluno-401154849741/iceberg/pedidos/'
TBLPROPERTIES (
  'table_type'='iceberg',
  'format'='parquet',
  'write_compression'='zstd'
);


-- validando tabelas
SHOW TABLES IN trabalho_final_aluno;


-- validando coluna data_pedido, o tipo correto e o date e n string
DESCRIBE pedidos_iceberg;

-- validando o retorno da tabela pedidos
SELECT COUNT(*) FROM pedidos_iceberg;