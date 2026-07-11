-- Extensiones necesarias para el esquema.
-- Convención de Supabase: instalar extensiones fuera de `public`.
create schema if not exists extensions;

-- pgcrypto: gen_random_uuid() para primary keys y gen_random_bytes() para
-- generar tokens opacos criptográficamente seguros (QR, recuperación de
-- entradas).
create extension if not exists pgcrypto with schema extensions;
