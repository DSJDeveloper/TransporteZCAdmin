import { supabase } from "./supabaseClient"

export interface Usuario {
  id: string
  email: string
  role: "admin" | "supervisor" | "student" | "driver"
  name: string | null
  updated_at: string
}

export interface UsuarioCreate {
  email: string
  password: string
  role: Usuario["role"]
  name: string
}

export interface UsuarioUpdate {
  email?: string
  password?: string
  role?: Usuario["role"]
  name?: string | null
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getUsuarios(): Promise<Usuario[]> {
  const { data: raw, error } = await supabase.rpc("manage_profile", {
    p_action: "list",
    p_user_id: null,
    p_email: null,
    p_password: null,
    p_role: null,
    p_name: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Usuario[]>
  if (!result.success) throw new Error(result.message ?? "Error al cargar los usuarios")
  return result.data ?? []
}

export async function createUsuario(input: UsuarioCreate): Promise<Usuario> {
  const { data: raw, error } = await supabase.rpc("manage_profile", {
    p_action: "create",
    p_user_id: null,
    p_email: input.email,
    p_password: input.password,
    p_role: input.role,
    p_name: input.name || null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Usuario>
  if (!result.success) throw new Error(result.message ?? "Error al crear el usuario")
  return result.data as Usuario
}

export async function updateUsuario(id: string, input: UsuarioUpdate): Promise<Usuario> {
  const { data: raw, error } = await supabase.rpc("manage_profile", {
    p_action: "update",
    p_user_id: id,
    p_email: input.email ?? null,
    p_password: input.password || null,
    p_role: input.role ?? null,
    p_name: input.name ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Usuario>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar el usuario")
  return result.data as Usuario
}

export async function deleteUsuario(id: string): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_profile", {
    p_action: "delete",
    p_user_id: id,
    p_email: null,
    p_password: null,
    p_role: null,
    p_name: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar el usuario")
}
