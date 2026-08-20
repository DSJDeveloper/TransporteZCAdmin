-- =============================================
-- Conductores (type=3) sin email propio
-- Se usa el email y UUID del cliente asociado (idclient)
-- =============================================

-- Usuarios encontrados (7):
--   117 (blanca)     → cliente 1 → email=Physioathlete.az@gmail.com
--   118 (azul)       → cliente 2 → email=gerzonzambrano16@gmail.com
--   119 (artillero)  → cliente 3 → email=Bvpa22@gmail.com
--   120 (kia)        → cliente 4 → email=Aputu2706@gmail.com
--   546 (lagris)     → cliente 5 → email=kalowayisr@gmail.com
--   643 (chupacabra) → cliente 6 → NO EXISTE → omitido
--   644 (chupacabra) → cliente 7 → email=delyszambrano105@gmail.con

INSERT INTO auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, invited_at, confirmation_token, confirmation_sent_at, created_at, updated_at, is_super_admin, raw_app_meta_data, raw_user_meta_data) VALUES
('00000000-0000-0000-0000-000000000000'::uuid, '6453e0e7-082b-4646-8559-0a0a44f94527'::uuid, 'authenticated', 'authenticated', 'Physioathlete.az@gmail.com', '$2y$10$8V3cvgHXwJEjk9mvH0JsB.2NaSEUITRktc2A46m8.xd4w3otzmTFO', NOW(), NULL, '', NULL, '2024-10-05 20:29:19', '2024-10-05 20:29:19', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "La Blanca"}'::jsonb),
('00000000-0000-0000-0000-000000000000'::uuid, 'c64db567-6fef-487a-9b69-aa8806154c3f'::uuid, 'authenticated', 'authenticated', 'gerzonzambrano16@gmail.com', '$2y$10$h.CuCYpGGfgMY.gLKoDUyeXST6irbnky6Mrm55hdopE5znq/CDL0m', NOW(), NULL, '', NULL, '2024-10-05 20:29:53', '2024-10-05 20:29:53', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "La azul"}'::jsonb),
('00000000-0000-0000-0000-000000000000'::uuid, '6de4106b-a631-4bf9-a7d8-c1a248a3f3ae'::uuid, 'authenticated', 'authenticated', 'Bvpa22@gmail.com', '$2y$10$7RQTUVkczjXsbFA.gP1wW.0jdsq6/4xcKF3hM9i/pV.bWjj8S2Uma', NOW(), NULL, '', NULL, '2024-10-05 20:30:14', '2024-10-05 20:30:14', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "El artillero"}'::jsonb),
('00000000-0000-0000-0000-000000000000'::uuid, '050353d8-8506-4ee5-97aa-1e26ecdbf7db'::uuid, 'authenticated', 'authenticated', 'Aputu2706@gmail.com', '$2y$10$A.m7I2Q4PfY4geIG8YYA9.pqGbUZIQyNw1QwF70RqxhDRCqqU2Kve', NOW(), NULL, '', NULL, '2024-10-05 20:30:45', '2024-10-05 20:30:45', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "La kia"}'::jsonb),
('00000000-0000-0000-0000-000000000000'::uuid, '251786b1-fb7a-4e35-be1d-b535cfede1c9'::uuid, 'authenticated', 'authenticated', 'kalowayisr@gmail.com', '$2y$10$7ok6wbgwt14mu.U0GdOa9uwd7fmrs.7XNvdGCR.D8fWQ20aRstuve', NOW(), NULL, '', NULL, '2025-05-05 14:58:49', '2025-05-05 14:58:49', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "La Gris"}'::jsonb),
('00000000-0000-0000-0000-000000000000'::uuid, 'd7f9a735-7d13-4ccb-89e0-464bfec4dc64'::uuid, 'authenticated', 'authenticated', 'delyszambrano105@gmail.con', '$2y$10$LReG85P7MGmsES2VW1YWUekHO9jSoW0Uv6s.2tiPfvH.WxcFZHGhq', NOW(), NULL, '', NULL, '2025-10-22 17:50:37', '2026-01-04 23:46:36', false, '{"provider": "email", "providers": ["email"]}'::jsonb, '{"user_name": "chupacabra"}'::jsonb);

-- =============================================
-- auth.identities (una por cada auth.user)
-- =============================================

INSERT INTO auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at) VALUES
('6453e0e7-082b-4646-8559-0a0a44f94527'::uuid, '6453e0e7-082b-4646-8559-0a0a44f94527'::uuid, '{"sub": "6453e0e7-082b-4646-8559-0a0a44f94527", "email": "Physioathlete.az@gmail.com"}'::jsonb, 'email', 'Physioathlete.az@gmail.com', NOW(), NOW(), NOW()),
('c64db567-6fef-487a-9b69-aa8806154c3f'::uuid, 'c64db567-6fef-487a-9b69-aa8806154c3f'::uuid, '{"sub": "c64db567-6fef-487a-9b69-aa8806154c3f", "email": "gerzonzambrano16@gmail.com"}'::jsonb, 'email', 'gerzonzambrano16@gmail.com', NOW(), NOW(), NOW()),
('6de4106b-a631-4bf9-a7d8-c1a248a3f3ae'::uuid, '6de4106b-a631-4bf9-a7d8-c1a248a3f3ae'::uuid, '{"sub": "6de4106b-a631-4bf9-a7d8-c1a248a3f3ae", "email": "Bvpa22@gmail.com"}'::jsonb, 'email', 'Bvpa22@gmail.com', NOW(), NOW(), NOW()),
('050353d8-8506-4ee5-97aa-1e26ecdbf7db'::uuid, '050353d8-8506-4ee5-97aa-1e26ecdbf7db'::uuid, '{"sub": "050353d8-8506-4ee5-97aa-1e26ecdbf7db", "email": "Aputu2706@gmail.com"}'::jsonb, 'email', 'Aputu2706@gmail.com', NOW(), NOW(), NOW()),
('251786b1-fb7a-4e35-be1d-b535cfede1c9'::uuid, '251786b1-fb7a-4e35-be1d-b535cfede1c9'::uuid, '{"sub": "251786b1-fb7a-4e35-be1d-b535cfede1c9", "email": "kalowayisr@gmail.com"}'::jsonb, 'email', 'kalowayisr@gmail.com', NOW(), NOW(), NOW()),
('d7f9a735-7d13-4ccb-89e0-464bfec4dc64'::uuid, 'd7f9a735-7d13-4ccb-89e0-464bfec4dc64'::uuid, '{"sub": "d7f9a735-7d13-4ccb-89e0-464bfec4dc64", "email": "delyszambrano105@gmail.con"}'::jsonb, 'email', 'delyszambrano105@gmail.con', NOW(), NOW(), NOW());

-- =============================================
-- public.profiles (una por cada conductor)
-- =============================================

-- INSERT INTO public.profiles (id, type, display_name, phone, address, status, created_at, updated_at) VALUES
-- ('6453e0e7-082b-4646-8559-0a0a44f94527'::uuid, 3, 'La Blanca', '', '', '0', '2024-10-05 20:29:19', '2024-10-05 20:29:19'),
-- ('c64db567-6fef-487a-9b69-aa8806154c3f'::uuid, 3, 'La azul', '', '', '0', '2024-10-05 20:29:53', '2024-10-05 20:29:53'),
-- ('6de4106b-a631-4bf9-a7d8-c1a248a3f3ae'::uuid, 3, 'El artillero', '', '', '0', '2024-10-05 20:30:14', '2024-10-05 20:30:14'),
-- ('050353d8-8506-4ee5-97aa-1e26ecdbf7db'::uuid, 3, 'La kia', '', '', '0', '2024-10-05 20:30:45', '2024-10-05 20:30:45'),
-- ('251786b1-fb7a-4e35-be1d-b535cfede1c9'::uuid, 3, 'La Gris', '', '', '0', '2025-05-05 14:58:49', '2025-05-05 14:58:49'),
-- ('d7f9a735-7d13-4ccb-89e0-464bfec4dc64'::uuid, 3, 'chupacabra', '', '', '0', '2025-10-22 17:50:37', '2026-01-04 23:46:36');

-- =============================================
-- Nota: usuario 643 (idclient=6) omitido porque
-- el cliente 6 no existe en la tabla clients
-- =============================================
