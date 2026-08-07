-- Tarefa 8: Query executiva dos Top 5 clientes

SELECT
    c.id_cliente,
    c.nome,
    c.sobrenome,
    c.cidade,
    c.estado,
    c.segmento,
    COUNT(p.id_pedido) AS total_pedidos,
    ROUND(
        SUM(
            (p.quantidade * p.preco_unitario * (1 - p.desconto))
            + p.frete
        ),
        2
    ) AS valor_total_gasto
FROM pedidos_iceberg AS p
INNER JOIN clientes_iceberg AS c
    ON p.id_cliente = c.id_cliente
GROUP BY
    c.id_cliente,
    c.nome,
    c.sobrenome,
    c.cidade,
    c.estado,
    c.segmento
ORDER BY valor_total_gasto DESC
LIMIT 5;