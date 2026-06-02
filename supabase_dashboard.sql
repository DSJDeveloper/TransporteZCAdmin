-- ============================================================
-- Dashboard RPCs for real-time KPI data
-- Execute in Supabase SQL Editor
-- ============================================================

-- 1. Returns all KPI values in one JSON call
CREATE OR REPLACE FUNCTION public.get_dashboard_kpis()
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'debtors_total',    COALESCE((SELECT SUM(balance) FROM public.clients WHERE balance < 0), 0),
    'debtors_count',    COALESCE((SELECT COUNT(*)  FROM public.clients WHERE balance < 0), 0),
    'active_clients',   COALESCE((SELECT COUNT(*)  FROM public.clients WHERE status = '0'), 0),
    'total_clients',    COALESCE((SELECT COUNT(*)  FROM public.clients), 0),
    'recharges_today',  COALESCE((SELECT COUNT(*)  FROM public.recharge  WHERE date = CURRENT_DATE), 0),
    'recharges_amount_today', COALESCE((SELECT SUM(amount) FROM public.recharge WHERE date = CURRENT_DATE), 0),
    'transactions_today', COALESCE((SELECT COUNT(*) FROM public.transactions WHERE created_at::date = CURRENT_DATE), 0)
  ) INTO result;
  RETURN result;
END;
$$;

-- 2. Daily reservations grouped by shedule (for Reservas Diarias table)
CREATE OR REPLACE FUNCTION public.get_daily_reservas(p_date DATE DEFAULT CURRENT_DATE)
RETURNS TABLE(shedule VARCHAR, count BIGINT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT t.shedule, COUNT(*)::BIGINT
  FROM public.transactions t
  WHERE t.created_at::date = p_date
  GROUP BY t.shedule
  ORDER BY t.shedule;
END;
$$;

-- 3. Weekly flow – last 7 days (for chart and Flujo Semanal)
CREATE OR REPLACE FUNCTION public.get_weekly_flow()
RETURNS TABLE(day DATE, count BIGINT, total_amount NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT DATE(t.created_at) as day, COUNT(*)::BIGINT, COALESCE(SUM(t.amount), 0) as total_amount
  FROM public.transactions t
  WHERE t.created_at >= NOW() - INTERVAL '7 days'
  GROUP BY DATE(t.created_at)
  ORDER BY day;
END;
$$;

-- 4. Recent unified movements (transactions + recharges)
CREATE OR REPLACE FUNCTION public.get_recent_movements(p_limit INT DEFAULT 5)
RETURNS TABLE(id BIGINT, type TEXT, description TEXT, amount NUMERIC, created_at TIMESTAMPTZ, client_name TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT sub.id, sub.type, sub.description, sub.amount, sub.created_at, sub.client_name
  FROM (
    SELECT t.id, 'transaction'::TEXT as type,
           COALESCE(t.shedule, 'Sin horario')::TEXT as description,
           t.amount, t.created_at::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.transactions t
    LEFT JOIN public.clients c ON c.id = t.idclient
    UNION ALL
    SELECT r.id, 'recharge'::TEXT as type,
           ('Recarga #' || r.id)::TEXT as description,
           r.amount, r."createAt"::TIMESTAMPTZ, c.name::TEXT as client_name
    FROM public.recharge r
    LEFT JOIN public.clients c ON c.id = r.idclient
  ) sub
  ORDER BY sub.created_at DESC
  LIMIT p_limit;
END;
$$;

-- 5. Reservation detail for a specific schedule on a date
CREATE OR REPLACE FUNCTION public.get_reservas_detail(p_date DATE, p_shedule VARCHAR)
RETURNS TABLE(id INT, client_name TEXT, amount NUMERIC, created_at TIMESTAMPTZ)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  RETURN QUERY
  SELECT t.id, c.name::TEXT, t.amount, t.created_at::TIMESTAMPTZ
  FROM public.transactions t
  LEFT JOIN public.clients c ON c.id = t.idclient
  WHERE t.created_at::date = p_date AND t.shedule = p_shedule
  ORDER BY t.created_at;
END;
$$;

-- 6. Monthly analysis summary (KPIs + daily breakdown + top clients)
CREATE OR REPLACE FUNCTION public.get_monthly_summary(p_year INT, p_month INT)
RETURNS JSON
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  result JSON;
BEGIN
  SELECT json_build_object(
    'total_transactions',   COALESCE((SELECT COUNT(*)  FROM public.transactions  WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'total_recharges',      COALESCE((SELECT COUNT(*)  FROM public.recharge       WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'transactions_amount',  COALESCE((SELECT SUM(amount) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'recharges_amount',     COALESCE((SELECT SUM(amount) FROM public.recharge    WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month), 0),
    'active_clients',       COALESCE((SELECT COUNT(DISTINCT idclient) FROM public.transactions WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month), 0),
    'daily_data',           COALESCE((
      SELECT json_agg(json_build_object(
        'day', COALESCE(t.day, r.day),
        'transactions', COALESCE(t.count, 0),
        'transactions_amount', COALESCE(t.amount, 0),
        'recharges', COALESCE(r.count, 0),
        'recharges_amount', COALESCE(r.amount, 0)
      ) ORDER BY COALESCE(t.day, r.day))
      FROM (
        SELECT DATE(created_at) as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY DATE(created_at)
      ) t
      FULL OUTER JOIN (
        SELECT date as day, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as amount
        FROM public.recharge
        WHERE EXTRACT(YEAR FROM date) = p_year AND EXTRACT(MONTH FROM date) = p_month
        GROUP BY date
      ) r ON t.day = r.day
    ), '[]'::JSON),
    'top_clients', COALESCE((
      SELECT json_agg(json_build_object(
        'name', c.name,
        'count', t.count,
        'total', t.total
      ) ORDER BY t.total DESC)
      FROM (
        SELECT idclient, COUNT(*)::INT as count, COALESCE(SUM(amount), 0) as total
        FROM public.transactions
        WHERE EXTRACT(YEAR FROM created_at) = p_year AND EXTRACT(MONTH FROM created_at) = p_month
        GROUP BY idclient
        ORDER BY total DESC
        LIMIT 10
      ) t
      JOIN public.clients c ON c.id = t.idclient
    ), '[]'::JSON)
  ) INTO result;
  RETURN result;
END;
$$;
