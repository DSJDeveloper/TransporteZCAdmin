-- Establece la zona horaria a nivel global para la base de datos
ALTER DATABASE postgres SET timezone TO 'America/Caracas';

-- Aplica la zona horaria a los roles principales de conexión y API
ALTER ROLE postgres SET timezone TO 'America/Caracas';
ALTER ROLE anon SET timezone TO 'America/Caracas';
ALTER ROLE authenticated SET timezone TO 'America/Caracas';
ALTER ROLE service_role SET timezone TO 'America/Caracas';