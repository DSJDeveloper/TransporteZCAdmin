import { supabase } from "./supabaseClient"

export interface Unit {
  id: number
  name: string
  number: string
  plate: string
  status: number
  driver: string
  idroute: number | null
  route_name?: string
  email: string
  photo_url: string | null
}

export interface UnitForm {
  name: string
  number: string
  plate: string
  status: number
  driver: string
  idroute: number | null
  email: string
  password: string
  photo_url: string | null
}

interface RpcResult<T> {
  success: boolean
  data?: T
  message?: string
}

export async function getUnits(): Promise<Unit[]> {
  const { data: raw, error } = await supabase.rpc("get_units")
  if (error) throw error
  const result = raw as unknown as { success: boolean; data?: Unit[]; message?: string }
  if (!result.success) throw new Error(result.message ?? "Error al cargar las unidades")
  return result.data ?? []
}

export interface UnitName {
  id: number
  name: string
}

export async function getUnitNames(): Promise<UnitName[]> {
  const { data: raw, error } = await supabase.rpc("get_unit_names")
  if (error) throw error
  return (raw ?? []) as UnitName[]
}

export async function createUnit(unit: UnitForm): Promise<Unit> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "create",
    p_unit_id: null,
    p_name: unit.name,
    p_number: unit.number,
    p_plate: unit.plate,
    p_status: unit.status,
    p_driver: unit.driver,
    p_idroute: unit.idroute ?? null,
    p_email: unit.email || null,
    p_password: unit.password || null,
    p_photo_url: unit.photo_url ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Unit>
  if (!result.success) throw new Error(result.message ?? "Error al crear la unidad")
  return result.data as Unit
}

export async function updateUnit(id: number, unit: Partial<UnitForm>): Promise<Unit> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "update",
    p_unit_id: id,
    p_name: unit.name ?? null,
    p_number: unit.number ?? null,
    p_plate: unit.plate ?? null,
    p_status: unit.status ?? null,
    p_driver: unit.driver ?? null,
    p_idroute: unit.idroute ?? null,
    p_email: unit.email ?? null,
    p_password: unit.password || null,
    p_photo_url: unit.photo_url ?? null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<Unit>
  if (!result.success) throw new Error(result.message ?? "Error al actualizar la unidad")
  return result.data as Unit
}

export async function deleteUnit(id: number): Promise<void> {
  const { data: raw, error } = await supabase.rpc("manage_unit", {
    p_action: "delete",
    p_unit_id: id,
    p_name: null,
    p_number: null,
    p_plate: null,
    p_status: null,
    p_driver: null,
    p_idroute: null,
    p_email: null,
    p_password: null,
    p_photo_url: null,
  })
  if (error) throw error
  const result = raw as unknown as RpcResult<never>
  if (!result.success) throw new Error(result.message ?? "Error al eliminar la unidad")
}

export async function uploadUnitPhoto(file: File, unitId: number): Promise<string> {
  const fileExt = file.name.split(".").pop()
  const fileName = `unit_${unitId}_${Date.now()}.${fileExt}`
  const filePath = `units/${fileName}`
  const { error: uploadError } = await supabase.storage
    .from("payments-evidence")
    .upload(filePath, file, { upsert: true })
  if (uploadError) throw uploadError
  const { data: urlData } = supabase.storage
    .from("payments-evidence")
    .getPublicUrl(filePath)
  return urlData.publicUrl
}
