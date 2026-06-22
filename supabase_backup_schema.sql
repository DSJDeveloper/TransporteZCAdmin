-- BACKUP: ESTRUCTURA DE TABLAS

CREATE TABLE IF NOT EXISTS public.clients (id bigint, name character varying(255), phone character varying(255), documentID character varying(255), email character varying(255), creditLimit character varying(255), status character varying(255), createAt timestamp without time zone, createBy character varying(255), carrer character varying(255), balance numeric, uid character varying(1000), idroute bigint, photo_url character varying(1000));

CREATE TABLE IF NOT EXISTS public.units (id bigint, name character varying(255), number character varying(255), plate character varying(255), status integer, driver character varying(255), idroute bigint, email character varying(255), photo_url character varying(1000));

CREATE TABLE IF NOT EXISTS public.recharge (id bigint, idclient integer, method character varying(255), ref character varying(255), picture character varying(1000), amount numeric, tasa numeric, date date, status integer, createBy character varying(255), createAt timestamp without time zone, updateAprobate timestamp without time zone, codigo_banco character varying(4), idroute bigint, tickets numeric, idshedule bigint);

CREATE TABLE IF NOT EXISTS public.careers (id bigserial, code character varying(20), description character varying(255), status smallint);
CREATE TABLE IF NOT EXISTS public.route_horarios (id bigint, idroute bigint, idhorario bigint);

CREATE TABLE IF NOT EXISTS public.company (id bigint, name character varying(255), rif character varying(255), phone character varying(255), ticket numeric, tasa numeric, account character varying(2000), phoneAccount character varying(255), rifAccount character varying(255));

CREATE TABLE IF NOT EXISTS public.profiles (id uuid, email text, role USER-DEFINED, updated_at timestamp with time zone, name text);

CREATE TABLE IF NOT EXISTS public.user_routes (id bigint, user_id uuid, idroute bigint, created_at timestamp with time zone);

CREATE TABLE IF NOT EXISTS public.transactions (id integer, uid character varying(255), idclient integer, createBy integer, amount numeric, status integer, created_at timestamp without time zone, idunit integer, shedule character varying(255), newBalanceClient numeric, idroute bigint);

CREATE TABLE IF NOT EXISTS public.horario (id bigint, code character varying(10), shudle character varying(20), status integer);

CREATE TABLE IF NOT EXISTS public.solicitude (id integer, date character varying(11), idclient integer, shedule character varying(255), route character varying(255), status smallint, idroute bigint);

CREATE TABLE IF NOT EXISTS public.debug_manage_profile (ts timestamp with time zone, action character varying, user_id uuid, email character varying, password_length integer, password_first_ascii integer, password_last_ascii integer, password_value character varying(100), role character varying, name character varying);

CREATE TABLE IF NOT EXISTS public.routes (id bigint, code character varying(20), description character varying(255), status integer, created_at timestamp without time zone, idbank_info bigint);

CREATE TABLE IF NOT EXISTS public.v_role (role text);

CREATE TABLE IF NOT EXISTS public.bank_info (id bigint, bank_name character varying(255), bank_code character varying(50), phone character varying(255), document_id character varying(255), status integer, created_at timestamp without time zone);

