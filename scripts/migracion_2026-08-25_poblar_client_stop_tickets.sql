-- ============================================================
-- Migración: 2026-08-25
-- Nombre: poblar_client_stop_tickets — Backfill desde clients.tickets
-- Propósito: Distribuir el saldo acumulado de tickets (clients.tickets)
--            en el inventario por parada (client_stop_tickets).
-- Reglas:
--   * Clientes con COALESCE(tickets,0) <> 0 y idroute IS NOT NULL.
--   * Paradas de la ruta (todas, sin filtro de stops.status).
--   * 1 sola parada → esa; varias → MIN(price), empate → MIN(id).
--   * UPSERT (idclient,idstop) sobre-escribe con el saldo actual de clients.tickets.
--   * NO toca clients.balance ni clients.tickets.
--   * Idempotente: puede ejecutarse múltiples veces sin duplicar tickets.
-- Ejecución: Supabase SQL Editor. Usar ROLLBACK para auditar sin persistir.
-- ============================================================

BEGIN;

-- 1) Staging: resolución de parada destino por cliente (auditable pre-persistencia)
CREATE TEMP TABLE tmp_cst_backfill ON COMMIT DROP AS
SELECT
    c.id::integer      AS idclient,
    c.idroute          AS idroute,
    target.id          AS idstop,
    c.tickets          AS tickets
FROM public.clients c
JOIN LATERAL (
    SELECT rs.id
    FROM public.route_stops rs
    WHERE rs.route_id = c.idroute
    ORDER BY rs.price ASC, rs.id ASC
    LIMIT 1
) target ON TRUE
WHERE COALESCE(c.tickets, 0) <> 0
  AND c.idroute IS NOT NULL;

-- 2) AUDITORÍA ANTES DE PERSISTIR

-- 2a) Resumen global
SELECT
    (SELECT COUNT(*) FROM tmp_cst_backfill)                                AS filas_a_insertar,
    (SELECT COALESCE(SUM(tickets),0) FROM tmp_cst_backfill)                AS tickets_a_migrar,
    (SELECT COALESCE(SUM(tickets),0) FROM public.clients
       WHERE COALESCE(tickets,0) <> 0 AND idroute IS NOT NULL)             AS tickets_eligibles_clients,
    (SELECT COUNT(*) FROM public.clients c
       WHERE COALESCE(c.tickets,0) <> 0 AND c.idroute IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM public.route_stops rs
                         WHERE rs.route_id = c.idroute))                   AS clientes_sin_paradas;

-- 2b) Distribución por parada
SELECT rs.route_id, rs.id AS idstop, s.name, rs.price,
       COUNT(*) AS clientes, SUM(t.tickets) AS tickets
FROM tmp_cst_backfill t
JOIN public.route_stops rs ON rs.id = t.idstop
JOIN public.stops s ON s.id = rs.stop_id
GROUP BY rs.route_id, rs.id, s.name, rs.price
ORDER BY rs.route_id, rs.price, rs.id;

-- 2c) Clientes excluidos (ruta sin paradas)
SELECT c.id, c.name, c.idroute, c.tickets
FROM public.clients c
WHERE COALESCE(c.tickets,0) <> 0 AND c.idroute IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.route_stops rs WHERE rs.route_id = c.idroute)
ORDER BY c.id;

-- 3) UPSERT (persistir)
INSERT INTO public.client_stop_tickets ("idclient","idroute","idstop","tickets","updated_at")
SELECT idclient, idroute, idstop, tickets, NOW()
FROM tmp_cst_backfill
ON CONFLICT ("idclient","idstop")
DO UPDATE SET
    "tickets"    = EXCLUDED."tickets",
    "updated_at" = NOW();

-- 4) VERIFICACIÓN FINAL: consistencia inventario vs clients
SELECT
    (SELECT COUNT(*) FROM public.client_stop_tickets)              AS filas_inventario,
    (SELECT COALESCE(SUM(tickets),0) FROM public.client_stop_tickets) AS tickets_en_inventario,
    (SELECT COALESCE(SUM(tickets),0) FROM public.clients)          AS tickets_totales_en_clients,
    (SELECT COALESCE(SUM(tickets),0) FROM public.clients
       WHERE COALESCE(tickets,0) <> 0 AND idroute IS NOT NULL)     AS tickets_clientes_con_ruta,
    (SELECT COALESCE(SUM(tickets),0) FROM tmp_cst_backfill)        AS tickets_insertados;

-- ROLLBACK;  -- descomentar para auditar sin persistir
COMMIT;
